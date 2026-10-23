// Artemis for Apple Watch: shares the child's location with the parent's display,
// and flags when the watch has probably been taken off.
//
// Setup (Xcode): new watchOS App target, paste this file, then
//   1. serverURL below points at the Render deployment; change it only if the server moves.
//   2. Info: add
//        NSLocationWhenInUseUsageDescription  "Shares where you are with your parent while you're out together."
//        NSHealthShareUsageDescription        "Checks whether your watch is still on your wrist. Heart rate never leaves the watch."
//        NSHealthUpdateUsageDescription       "Runs a short activity session so the on-wrist check stays accurate."
//   3. Signing & Capabilities: add HealthKit, and Background Modes > Location updates + Workout processing.
//
// Watch-off check: heart rate is read only on the watch. If there are no heart-rate readings
// AND no movement for 60 s, the watch reports "off". Only "on"/"off" and the time it was
// last confirmed on the wrist are sent; heart-rate values never leave the watch.
// Frequent heart-rate readings need a workout session; Apple may question that in App Review.
import SwiftUI
import CoreLocation
import CoreMotion
import HealthKit
import WatchKit

@main
struct ArtemisWatchApp: App {
    @StateObject private var sharer = LocationSharer()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(sharer) }
    }
}

struct ContentView: View {
    @EnvironmentObject var sharer: LocationSharer
    @AppStorage("artemis-name") private var name = ""
    @AppStorage("artemis-code") private var code = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if sharer.isSharing {
                    Image(systemName: "location.fill").font(.title).foregroundStyle(.green)
                    Text("Sharing your location").font(.headline)
                    Text(sharer.status).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Stop sharing", role: .destructive) { sharer.stop() }
                } else {
                    TextField("Your name", text: $name)
                    TextField("Family code", text: $code)
                        .textInputAutocapitalization(.characters)
                    Button("Start sharing") { sharer.start(name: name, code: code.uppercased()) }
                        .disabled(name.isEmpty || code.count < 8)
                    if !sharer.status.isEmpty {
                        Text(sharer.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

final class LocationSharer: NSObject, ObservableObject, CLLocationManagerDelegate,
                            HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let serverURL = URL(string: "https://artemis-gqvn.onrender.com/api/loc")!
    static let interval: TimeInterval = 15        // parent display flags "signal lost" after 30 s
    static let offWristAfter: TimeInterval = 60   // no heart rate and no movement for this long = "off"

    @Published var isSharing = false
    @Published var status = ""

    private let manager = CLLocationManager()
    private let health = HKHealthStore()
    private let motion = CMMotionManager()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var lastHR: Date?          // last time a heart-rate reading arrived
    private var lastMove = Date()
    private var name = "", code = ""
    private var lastSent = Date.distantPast
    private var lastLoc: CLLocation?
    private var heartbeat: Timer?      // resends the last fix so a child standing still isn't "signal lost"
    private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "artemis-id") { return id }
        let id = "w-" + UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(id, forKey: "artemis-id")
        return id
    }()

    /// nil until the first heart-rate reading, then "on" or "off".
    private var wristState: String? {
        guard let hr = lastHR else { return nil }
        let now = Date()
        let onWrist = now.timeIntervalSince(hr) < Self.offWristAfter
                   || now.timeIntervalSince(lastMove) < Self.offWristAfter
        return onWrist ? "on" : "off"
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }

    func start(name: String, code: String) {
        self.name = name
        self.code = code
        isSharing = true
        status = "Waiting for GPS…"
        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        startWristCheck()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self, let loc = self.lastLoc,
                  Date().timeIntervalSince(self.lastSent) >= Self.interval - 1 else { return }
            self.lastSent = Date()
            self.send(loc)
        }
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        lastLoc = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        stopWristCheck()
        isSharing = false
        status = ""
    }

    // MARK: Location

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isSharing, let loc = locations.last else { return }
        lastLoc = loc
        guard Date().timeIntervalSince(lastSent) >= Self.interval else { return }
        lastSent = Date()
        send(loc)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        status = "Location error: \(error.localizedDescription)"
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted {
            stop()
            status = "Allow location for Artemis in Settings."
        }
    }

    // MARK: Watch-off check

    private func startWristCheck() {
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.5
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                if abs(g - 1) > 0.03 { self?.lastMove = Date() }
            }
        }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        health.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                    read: [HKQuantityType(.heartRate)]) { [weak self] ok, _ in
            guard ok else { return }
            DispatchQueue.main.async { self?.startWorkout() }
        }
    }

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .outdoor
        do {
            let s = try HKWorkoutSession(healthStore: health, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            let startDate = Date()
            s.startActivity(with: startDate)
            b.beginCollection(withStart: startDate) { _, _ in }
        } catch {
            status = "Watch-off check unavailable on this watch."
        }
    }

    private func stopWristCheck() {
        motion.stopAccelerometerUpdates()
        session?.end()
        session = nil
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.discardWorkout()   // nothing is saved to the Health app
            self?.builder = nil
        }
        lastHR = nil
    }

    func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard types.contains(HKQuantityType(.heartRate)) else { return }
        DispatchQueue.main.async { self.lastHR = Date() }   // only the time is kept, not the value
    }
    func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                        from: HKWorkoutSessionState, date: Date) {}
    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.status = "Watch-off check stopped: \(error.localizedDescription)" }
    }

    // MARK: Network

    private func send(_ loc: CLLocation) {
        var body: [String: Any] = [
            "family": code, "id": deviceID, "name": name,
            "lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy
        ]
        let level = WKInterfaceDevice.current().batteryLevel
        if level >= 0 { body["battery"] = Int(level * 100) }
        if let w = wristState { body["wrist"] = w }
        if let hr = lastHR { body["wristTs"] = Int(hr.timeIntervalSince1970 * 1000) }

        var req = URLRequest(url: Self.serverURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                self.status = ok
                    ? "Updated \(Date().formatted(date: .omitted, time: .shortened)), ±\(Int(loc.horizontalAccuracy)) m"
                    : "Couldn’t reach the server. Retrying."
            }
        }.resume()
    }
}
