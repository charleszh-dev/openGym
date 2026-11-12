import CoreLocation
import Foundation
import HealthKit
import WeatherKit

/**
 * Where a live workout happened, and the weather there, on the iPhone (iOS 26, PhoneWorkoutPlugin)
 * and the Apple Watch (WorkoutManager). One type for both, because both save one HKWorkout and
 * HealthKit attaches a place the same way.
 *
 * Apple's own Fitness shows a pin for a strength workout and a path for a walk, run or ride, plus
 * the weather on either. HealthKit has no pin of its own: the place is an HKWorkoutRoute, one
 * location when the session did not move, the path when it did (`path`). Weather is metadata on
 * the workout, so it is added before finishWorkout. The route is attached after, which HealthKit
 * requires. A missing fix, a refused permission or WeatherKit failing leaves the workout saved.
 *
 * Compiled into both targets. Not in WatchCore: that package stays free of HealthKit so `swift test`
 * can build it. WeatherKit needs iOS 16; the iPhone session that uses this is iOS 26.
 */
@available(iOS 16.0, watchOS 9.0, *)
final class WorkoutLocation: NSObject, CLLocationManagerDelegate {
    private let store: HKHealthStore
    /// A walk, run or ride outside: keep the path. Anything else: one location, the place it happened.
    private let path: Bool
    private let manager = CLLocationManager()
    private var route: HKWorkoutRouteBuilder?
    private var points: [CLLocation] = []
    private var place: CLLocation?
    private var weather: [String: Any] = [:]
    private var lookedUp = false
    private var askedLocation = false
    private var backgroundOn = false
    private var lookup: Task<Void, Never>?

    /// A place this accurate is enough to stop listening. A path keeps every tighter fix.
    private static let placeAccuracy: CLLocationAccuracy = 100
    private static let pathAccuracy: CLLocationAccuracy = 50

    init(store: HKHealthStore, path: Bool) {
        self.store = store
        self.path = path
        super.init()
    }

    /// Starts listening. Asks for location once, and to write a route if that was not granted yet
    /// (the original Health permission may predate routes).
    func start() {
        let run = { self.startOnMain() }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private func startOnMain() {
        guard route == nil else { return }
        route = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        let routeType = HKSeriesType.workoutRoute()
        if store.authorizationStatus(for: routeType) != .sharingAuthorized {
            store.requestAuthorization(toShare: [routeType], read: []) { _, _ in }
        }
        manager.delegate = self
        manager.activityType = path ? .fitness : .other
        manager.desiredAccuracy = path ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = path ? 10 : kCLDistanceFilterNone
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
        // Background updates are for a path that continues with the phone locked. A place is one
        // fix at the start, and the gym reminder does not use this mode.
        if path {
            manager.pausesLocationUpdatesAutomatically = false
            if !backgroundOn {
                manager.allowsBackgroundLocationUpdates = true
                backgroundOn = true
            }
        }
        #endif
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        beginUpdatesIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let valid = locations.filter { $0.horizontalAccuracy >= 0 }
        guard !valid.isEmpty else { return }
        if !lookedUp, let loc = valid.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            lookedUp = true
            lookup = Task { await self.lookupWeather(loc) }
        }
        if path {
            points.append(contentsOf: valid.filter { $0.horizontalAccuracy <= Self.pathAccuracy })
            return
        }
        if let loc = valid.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }),
           place == nil || loc.horizontalAccuracy < place!.horizontalAccuracy {
            place = loc
        }
        if let place = place, place.horizontalAccuracy <= Self.placeAccuracy { stopUpdating() }
    }

    /// Stops the radio. A fix already taken stays, for a save that follows.
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
        place = nil
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

    /// Attaches the place, or the path, to a workout that is already in Apple Health. Calls `done` either way.
    func finish(with workout: HKWorkout, done: @escaping () -> Void) {
        let go = {
            self.stopUpdating()
            guard let builder = self.route else { done(); return }
            self.route = nil
            let taken = self.locations(from: workout.startDate, to: workout.endDate)
            self.points = []
            self.place = nil
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

    /// Points whose times fall inside the workout. A place taken a moment outside that is moved
    /// onto the workout's own interval, so HealthKit will keep it.
    private func locations(from start: Date, to end: Date) -> [CLLocation] {
        if path {
            return points.filter { $0.timestamp >= start && $0.timestamp <= end }
        }
        guard let place = place else { return [] }
        let stamp = min(max(place.timestamp, start), end)
        guard stamp != place.timestamp else { return [place] }
        return [CLLocation(coordinate: place.coordinate, altitude: place.altitude,
                            horizontalAccuracy: place.horizontalAccuracy, verticalAccuracy: place.verticalAccuracy,
                            timestamp: stamp)]
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
            // No weather on the workout. The place, if any, is unaffected.
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
