import CoreLocation
import Foundation
import HealthKit
import WeatherKit

/**
 * The GPS route and the one weather reading of an outdoor live session, on the iPhone (iOS 26,
 * PhoneWorkoutPlugin) and the Apple Watch (WorkoutManager). Indoor sessions never make one.
 *
 * The route is attached after the workout is saved (HealthKit requires that). Weather is metadata
 * on the workout itself, so it has to be added before finishWorkout. Either one failing leaves the
 * workout in Apple Health: a refused permission, no GPS fix, or WeatherKit down.
 *
 * Compiled into both targets. Not in WatchCore: that package stays free of HealthKit so `swift test`
 * can build it. WeatherKit needs iOS 16; the iPhone session that uses this is iOS 26.
 */
@available(iOS 16.0, watchOS 9.0, *)
final class WorkoutRouteRecorder: NSObject, CLLocationManagerDelegate {
    private let store: HKHealthStore
    private let outdoor: Bool
    private let manager = CLLocationManager()
    private var route: HKWorkoutRouteBuilder?
    private var points: [CLLocation] = []
    private var weather: [String: Any] = [:]
    private var lookedUp = false
    private var askedLocation = false
    private var backgroundOn = false
    private var lookup: Task<Void, Never>?

    init(store: HKHealthStore, outdoor: Bool) {
        self.store = store
        self.outdoor = outdoor
        super.init()
    }

    /// Starts listening when this is an outdoor session and location is allowed. Asks once when it
    /// has not been asked yet. Also asks to write a workout route, which the original Health
    /// permission may not have included.
    func start() {
        guard outdoor else { return }
        let run = { self.startOnMain() }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private func startOnMain() {
        guard outdoor, route == nil else { return }
        route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let routeType = HKSeriesType.workoutRoute()
        if store.authorizationStatus(for: routeType) != .sharingAuthorized {
            store.requestAuthorization(toShare: [routeType], read: []) { _, _ in }
        }
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        beginUpdatesIfAllowed()
    }

    private func beginUpdatesIfAllowed() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            guard !askedLocation else { return }
            askedLocation = true
            manager.requestWhenInUseAuthorization()
            return
        }
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        #if os(iOS)
        manager.pausesLocationUpdatesAutomatically = false
        if !backgroundOn {
            manager.allowsBackgroundLocationUpdates = true
            backgroundOn = true
        }
        #endif
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        beginUpdatesIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let valid = locations.filter { $0.horizontalAccuracy >= 0 }
        // A first fix is often rough. The route keeps the tighter ones; weather can use a coarser
        // point, because it only needs to be near where the session is.
        let tight = valid.filter { $0.horizontalAccuracy <= 50 }
        points.append(contentsOf: tight)
        let needWeather = !lookedUp && !valid.isEmpty
        if needWeather { lookedUp = true }
        if needWeather, let loc = valid.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            lookup = Task { await self.lookupWeather(loc) }
        }
    }

    /// Stops the radio. Points already taken stay, for a save that follows.
    func stopUpdating() {
        let run = {
            self.manager.stopUpdatingLocation()
            #if os(iOS)
            if self.backgroundOn {
                self.manager.allowsBackgroundLocationUpdates = false
                self.backgroundOn = false
            }
            #endif
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
    }

    /// The session was discarded: nothing is written.
    func discard() {
        stopUpdating()
        lookup?.cancel()
        points = []
        weather = [:]
        route = nil
    }

    /// The weather metadata, waiting briefly for a lookup that is still in flight. Empty when there
    /// was no fix or WeatherKit failed: the caller saves the workout either way.
    func weatherMetadata(_ done: @escaping ([String: Any]) -> Void) {
        let task = lookup
        Task {
            if let task = task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await task.value }
                    group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
            // The lookup writes `weather` on the main queue before its task ends, so this read
            // sees it. A lookup that is still going (the wait above gave up) contributes nothing.
            DispatchQueue.main.async { done(self.weather) }
        }
    }

    /// Attaches the route to a workout that is already in Apple Health. Calls `done` either way.
    func finishRoute(with workout: HKWorkout, done: @escaping () -> Void) {
        let go = {
            self.stopUpdating()
            guard let builder = self.route else { done(); return }
            self.route = nil
            let start = workout.startDate, end = workout.endDate
            let taken = self.points.filter { $0.timestamp >= start && $0.timestamp <= end }
            self.points = []
            guard !taken.isEmpty else { done(); return }
            Task {
                do {
                    var index = 0
                    while index < taken.count {
                        let endIndex = min(index + 100, taken.count)
                        try await builder.insertRouteData(Array(taken[index..<endIndex]))
                        index = endIndex
                    }
                    _ = try await builder.finishRoute(with: workout, metadata: nil)
                } catch {
                    // No route permission, or HealthKit refused the points. The workout stays.
                }
                done()
            }
        }
        if Thread.isMainThread { go() } else { DispatchQueue.main.async(execute: go) }
    }

    private func lookupWeather(_ loc: CLLocation) async {
        guard !Task.isCancelled else { return }
        do {
            let current = try await WeatherService.shared.weather(for: loc).currentWeather
            guard !Task.isCancelled else { return }
            let celsius = current.temperature.converted(to: .celsius).value
            let meta: [String: Any] = [
                HKMetadataKeyWeatherCondition: NSNumber(value: Self.healthCondition(current.condition).rawValue),
                HKMetadataKeyWeatherTemperature: HKQuantity(unit: .degreeCelsius(), doubleValue: celsius),
                // percent() takes a fraction: 1 is 100%. WeatherKit's humidity is already that.
                HKMetadataKeyWeatherHumidity: HKQuantity(unit: .percent(), doubleValue: current.humidity),
            ]
            await MainActor.run { self.weather = meta }
        } catch {
            // No weather on the workout. The route, if any, is unaffected.
        }
    }

    /// WeatherKit's conditions onto the smaller set HealthKit stores on a workout.
    private static func healthCondition(_ condition: WeatherCondition) -> HKWeatherCondition {
        switch condition {
        case .clear: return .clear
        case .mostlyClear: return .fair
        case .partlyCloudy: return .partlyCloudy
        case .mostlyCloudy: return .mostlyCloudy
        case .cloudy: return .cloudy
        case .foggy: return .foggy
        case .haze: return .haze
        case .breezy, .windy: return .windy
        case .smoky: return .smoky
        case .blowingDust: return .dust
        case .snow, .flurries, .sunFlurries, .heavySnow, .blizzard, .blowingSnow: return .snow
        case .hail: return .hail
        case .sleet: return .sleet
        case .freezingDrizzle: return .freezingDrizzle
        case .freezingRain: return .freezingRain
        case .wintryMix: return .mixedRainAndSnow
        case .drizzle: return .drizzle
        case .rain, .heavyRain: return .showers
        case .sunShowers: return .scatteredShowers
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms: return .thunderstorms
        case .tropicalStorm: return .tropicalStorm
        case .hurricane: return .hurricane
        case .hot, .frigid: return .none
        @unknown default: return .none
        }
    }
}

/// Routes are not removed with the workout they belong to. Callers delete these first.
enum WorkoutRoutes {
    static func remove(store: HKHealthStore, from workouts: [HKWorkout], group: DispatchGroup) {
        let type = HKSeriesType.workoutRoute()
        for w in workouts {
            group.enter()
            store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(from: w)) { _, _, _ in group.leave() }
        }
    }

    static func remove(store: HKHealthStore, from workouts: [HKWorkout], done: @escaping () -> Void) {
        let group = DispatchGroup()
        remove(store: store, from: workouts, group: group)
        group.notify(queue: .global()) { done() }
    }

    static func remove(store: HKHealthStore, from workouts: [HKWorkout]) async {
        guard !workouts.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            remove(store: store, from: workouts, group: group)
            group.notify(queue: .global()) { cont.resume() }
        }
    }
}
