import Foundation
import UserNotifications
import XCTest
@testable import PrintGlance

/// Stands in for one printer connection. The test plays the printer: `accept()`, `report(_:)`, `drop(_:)`.
final class FakeMQTT: MQTTSession {
    struct Dial: Equatable {
        var host: String
        var port: UInt16
        var clientID: String
        var username: String
        var password: String
    }

    var onConnect: (() -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onMessage: ((String, Data) -> Void)?
    private(set) var dials: [Dial] = []
    private(set) var subscriptions: [String] = []
    private(set) var publishes: [(topic: String, payload: String)] = []
    private(set) var disconnects = 0

    func connect(host: String, port: UInt16, clientID: String, username: String, password: String) {
        dials.append(Dial(host: host, port: port, clientID: clientID, username: username, password: password))
    }

    func subscribe(_ topic: String) { subscriptions.append(topic) }

    func publish(topic: String, payload: Data) {
        publishes.append((topic, String(decoding: payload, as: UTF8.self)))
    }

    func disconnect() { disconnects += 1 }

    /// The printer took the access code (CONNACK 0).
    func accept() { onConnect?() }

    /// One `device/<serial>/report` message, as `{"print": …}`.
    func report(_ print: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: ["print": print])
        onMessage?("device/report", data)
    }

    /// Raw bytes from the printer, for hostile payloads.
    func send(_ raw: Data) { onMessage?("device/report", raw) }

    /// "MQTT CONNACK 5" is a rejected access code, "ECONNREFUSED" a refused socket.
    func drop(_ reason: String?) { onDisconnect?(reason) }
}

/// Every connection GlanceModel opened, oldest first. Saving settings tears all links down and opens new ones.
final class FakePrinters {
    private(set) var clients: [FakeMQTT] = []

    func make() -> any MQTTSession {
        let client = FakeMQTT()
        clients.append(client)
        return client
    }

    /// The newest connection for this printer, found by the serial's last six characters in the client ID.
    func latest(_ serial: String) -> FakeMQTT? {
        clients.last { $0.dials.first?.clientID.contains("-\(serial.suffix(6))-") == true }
    }
}

/// What GlanceModel asked of Notification Center. Plain values, so assertions read like the banner.
/// `@unchecked Sendable`: tests run on the main thread, and the async closures need a Sendable capture.
final class NotificationLog: @unchecked Sendable {
    struct Posted: Equatable {
        var id: String
        var title: String
        var body: String
        var serial: String?
        /// Seconds until it fires; nil for now.
        var fireIn: TimeInterval?
        var calendar: DateComponents?
    }

    var posted: [Posted] = []
    var cancelled: [String] = []
    var permissionRequests = 0
    var denied = false

    var notifier: Notifier {
        Notifier(
            add: { [self] request in
                var fireIn: TimeInterval?
                var calendar: DateComponents?
                if let t = request.trigger as? UNTimeIntervalNotificationTrigger { fireIn = t.timeInterval }
                if let t = request.trigger as? UNCalendarNotificationTrigger { calendar = t.dateComponents }
                posted.append(Posted(
                    id: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    serial: request.content.userInfo[PendingSelection.serialKey] as? String,
                    fireIn: fireIn,
                    calendar: calendar
                ))
            },
            removePending: { [self] ids in cancelled.append(contentsOf: ids) },
            requestAuthorization: { [self] in permissionRequests += 1 },
            isDenied: { [self] in denied }
        )
    }

    func titles() -> [String] { posted.map(\.title) }
}

/// The Wi-Fi as discovery sees it. `@unchecked Sendable` for the same reason as `NotificationLog`.
final class FakeNetwork: @unchecked Sendable {
    var hits: [PrinterDiscovery.Hit] = []
    var scans = 0

    var scan: @Sendable () async -> [PrinterDiscovery.Hit] {
        { [self] in
            scans += 1
            return hits
        }
    }
}

/// A GlanceModel wired to fakes, with its own preferences domain, history file, and log.
@MainActor
final class ModelHarness {
    let defaults: UserDefaults
    let dir: URL
    let printers = FakePrinters()
    let notifications = NotificationLog()
    let network = FakeNetwork()
    private(set) var model: GlanceModel!

    var logText: String { (try? String(contentsOf: dir.appendingPathComponent("PrintGlance.log"), encoding: .utf8)) ?? "" }
    var jobsURL: URL { dir.appendingPathComponent("jobs.json") }

    /// `saved` is written before the model loads, like printers a previous launch saved.
    init(_ test: XCTestCase, saved: SavedPrinters = .empty, connectTimeout: Duration = .seconds(60)) {
        defaults = test.scratchDefaults()
        dir = test.scratchDirectory()
        saved.save(to: defaults)
        model = makeModel(connectTimeout: connectTimeout)
    }

    /// A fresh model over the same preferences and history, like relaunching the app.
    func relaunch(connectTimeout: Duration = .seconds(60)) {
        model = makeModel(connectTimeout: connectTimeout)
    }

    private func makeModel(connectTimeout: Duration) -> GlanceModel {
        GlanceModel(
            jobLogURL: jobsURL,
            defaults: defaults,
            logURL: dir.appendingPathComponent("PrintGlance.log"),
            notifier: notifications.notifier,
            makeClient: { [printers] in printers.make() },
            scan: network.scan,
            connectTimeout: connectTimeout
        )
    }

    /// Adds printers the way the setup window does and returns each one's connection.
    @discardableResult
    func add(_ list: PrinterSettings...) -> [FakeMQTT] {
        var next = model.settings
        for p in list { next = next.adding(p) }
        model.saveSettings(next)
        return list.map { printers.latest($0.serial)! }
    }

    var doc: PrintDoc? {
        if case let .doc(doc) = model.content.result { return doc }
        return nil
    }

    func row(_ serial: String) -> Printer? {
        doc?.printers.first { $0.id == serial }
    }
}

/// A count a polling closure can read. Swift 6 won't let a `@MainActor` closure capture a `var`.
@MainActor
final class Counter {
    var count = 0
}

extension PrinterSettings {
    static func x2d(ip: String = "192.0.2.10", code: String = "a1b2c3d4") -> PrinterSettings {
        PrinterSettings(ip: ip, serial: "20P9AJ5B0700123", accessCode: code, name: "X2D")
    }

    static func p1s(ip: String = "192.0.2.11", code: String = "p1s-code") -> PrinterSettings {
        PrinterSettings(ip: ip, serial: "01P00A411800456", accessCode: code, name: "P1S")
    }
}

extension XCTestCase {
    /// A throwaway preferences domain, removed after the test. Tests never write `UserDefaults.standard`.
    func scratchDefaults() -> UserDefaults {
        let name = "PrintGlanceTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A temporary directory, removed after the test.
    func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrintGlanceTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    func eventually(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date() + timeout
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Bambu `print` reports, trimmed to the fields the app reads.
enum Report {
    static func running(
        percent: Int = 52,
        minutesLeft: Int = 84,
        job: String = "Benchy",
        task: String = "t1",
        layer: Int = 18,
        total: Int = 29
    ) -> [String: Any] {
        [
            "gcode_state": "RUNNING",
            "mc_percent": percent,
            "mc_remaining_time": minutesLeft,
            "subtask_name": job,
            "task_id": task,
            "layer_num": layer,
            "total_layer_num": total,
        ]
    }

    static func state(_ state: String, task: String = "t1") -> [String: Any] {
        ["gcode_state": state, "task_id": task]
    }

    /// One AMS with the active spool in A1 at `remain` percent.
    static func ams(remain: Int, trayNow: Int = 0) -> [String: Any] {
        [
            "ams": [
                "tray_now": "\(trayNow)",
                "ams": [[
                    "id": "0",
                    "humidity": "4",
                    "tray": [
                        ["id": "0", "tray_type": "PLA", "tray_info_idx": "GFA01", "remain": remain, "tray_color": "F5C6A0FF"],
                        ["id": "1", "tray_type": "PETG", "tray_info_idx": "GFG02", "remain": 60, "tray_color": "2850E0FF"],
                    ],
                ]],
            ],
        ]
    }
}

extension Dictionary where Key == String, Value == Any {
    func merging(_ other: [String: Any]) -> [String: Any] {
        merging(other) { _, new in new }
    }
}
