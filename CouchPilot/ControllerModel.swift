import AppKit
import GameController
import SwiftUI
import UniformTypeIdentifiers

struct LogEvent: Codable, Identifiable {
    var id = UUID()
    var timestamp: String
    var uptimeMilliseconds: Double
    var device: String
    var appState: String
    var backgroundMonitoring: Bool
    var type: String
    var input: String
    var value: String
    var durationMilliseconds: Double?
    var longPress600ms: Bool?
}

struct ExportData: Codable {
    let events: [LogEvent]
    let manualResults: [String: String]
}

final class ControllerModel: ObservableObject {
    @Published var device = "未连接"
    @Published var profile = "—"
    @Published var homeInfo = "等待手柄"
    @Published var buttons: [String: Float] = [:]
    @Published var left = CGPoint.zero
    @Published var right = CGPoint.zero
    @Published var events: [LogEvent] = []
    @Published var background = false {
        didSet { GCController.shouldMonitorBackgroundEvents = background; log("setting", "backgroundMonitoring", String(background)) }
    }
    @Published var gestureDisabled = false {
        didSet { applyGesture() }
    }
    @Published var results: [String: String] = UserDefaults.standard.dictionary(forKey: "manualResults") as? [String: String] ?? [:]
    @Published var note = ""
    private var controller: GCController?
    private var pressedStates: [String: Bool] = [:]
    private var homeDown: UInt64?
    private var homeTimer: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let clock = ISO8601DateFormatter()

    init() {
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        GCController.shouldMonitorBackgroundEvents = false
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.log("focus", "application", NSApp.isActive ? "foreground" : "background")
            })
        }
        log("session", "launch", "diagnostics started")
        refresh()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func refresh() {
        let next = GCController.controllers().first
        if controller === next { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        homeTimer?.cancel(); homeDown = nil
        controller = next; buttons = [:]; pressedStates = [:]; left = .zero; right = .zero
        guard let c = next else {
            device = "未连接"; profile = "—"; homeInfo = "未连接：无法判断 Home 是否暴露"; log("connection", "controller", "disconnected / none"); return
        }
        device = c.vendorName ?? "未知设备"
        profile = c.extendedGamepad != nil ? "Physical Input + Extended Gamepad" : "Physical Input；无 Extended Gamepad（此工具的输入视图不可用）"
        log("connection", "controller", "connected: \(device); \(profile)")
        guard let gamepad = c.extendedGamepad else { homeInfo = "无 Extended Gamepad，无法通过该 profile 读取 Home"; return }
        applyGesture()
        gamepad.valueChangedHandler = { [weak self, weak c] gamepad, element in
            guard let self, let c else { return }
            // Snapshot values at callback time; UI and event mutations remain on the main queue.
            let lx = gamepad.leftThumbstick.xAxis.value, ly = gamepad.leftThumbstick.yAxis.value
            let rx = gamepad.rightThumbstick.xAxis.value, ry = gamepad.rightThumbstick.yAxis.value
            let pairs: [(String, GCControllerButtonInput)] = [("A",gamepad.buttonA),("B",gamepad.buttonB),("X",gamepad.buttonX),("Y",gamepad.buttonY),("LB",gamepad.leftShoulder),("RB",gamepad.rightShoulder),("LT",gamepad.leftTrigger),("RT",gamepad.rightTrigger),("Up",gamepad.dpad.up),("Down",gamepad.dpad.down),("Left",gamepad.dpad.left),("Right",gamepad.dpad.right)] + (gamepad.buttonHome.map { [("Home", $0)] } ?? [])
            let changed = pairs.map { ($0.0, $0.1.value, $0.1.isPressed) }
            let stick = element === gamepad.leftThumbstick ? "Left stick" : (element === gamepad.rightThumbstick ? "Right stick" : nil)
            let tick = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                guard self.controller === c else { return }
                self.left = CGPoint(x: Double(lx), y: Double(ly)); self.right = CGPoint(x: Double(rx), y: Double(ry))
                if let stick { self.log("axis", stick, stick == "Left stick" ? "\(lx),\(ly)" : "\(rx),\(ry)", tick: tick) }
                for (name, value, pressed) in changed { self.updateButton(name, value: value, pressed: pressed, tick: tick) }
            }
        }
    }
    func applyGesture() {
        guard let home = controller?.extendedGamepad?.buttonHome else {
            if controller != nil { homeInfo = "buttonHome 未暴露；无法读取或控制系统手势。原因可能是设备、接收器映射或系统，不能仅凭此确定。" }
            return
        }
        home.preferredSystemGestureState = gestureDisabled ? .disabled : .enabled
        homeInfo = "buttonHome 已暴露 · isBoundToSystemGesture: \(home.isBoundToSystemGesture) · preferred: \(home.preferredSystemGestureState == .disabled ? "disabled" : "enabled")（系统不保证遵从）"
        log("setting", "Home gesture", homeInfo)
    }
    func updateButton(_ name: String, value: Float, pressed: Bool, tick: UInt64) {
        let wasPressed = pressedStates[name] ?? false
        pressedStates[name] = pressed
        buttons[name] = value
        guard pressed != wasPressed else { return }
        if name == "Home" && pressed {
            homeDown = tick
            homeTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.homeDown == tick else { return }
                self.log("threshold", "Home", "600ms reached", duration: 600, long: true)
            }
            homeTimer = work; DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600), execute: work)
        }
        var duration: Double? = nil
        if name == "Home" && !pressed {
            homeTimer?.cancel()
            if let start = homeDown, tick >= start { duration = Double(tick - start) / 1_000_000 }
            homeDown = nil
        }
        log(pressed ? "press" : "release", name, String(format: "%.3f", value), duration: duration, long: duration.map { $0 >= 600 }, tick: tick)
    }
    func log(_ type: String, _ input: String, _ value: String, duration: Double? = nil, long: Bool? = nil, tick: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        events.append(LogEvent(timestamp: clock.string(from: Date()), uptimeMilliseconds: Double(tick) / 1_000_000, device: device, appState: NSApp.isActive ? "foreground" : "background", backgroundMonitoring: background, type: type, input: input, value: value, durationMilliseconds: duration, longPress600ms: long))
    }
    func setResult(_ key: String, _ value: String) { results[key] = value; UserDefaults.standard.set(results, forKey: "manualResults"); log("manual", key, value) }
    func export(csv: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = csv ? "CouchPilot-events.csv" : "CouchPilot-events.json"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv {
                func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                let header = "timestamp,uptimeMilliseconds,device,appState,backgroundMonitoring,type,input,value,durationMilliseconds,longPress600ms\n"
                let rows = events.map { e in [e.timestamp,String(e.uptimeMilliseconds),e.device,e.appState,String(e.backgroundMonitoring),e.type,e.input,e.value,e.durationMilliseconds.map { String($0) } ?? "",e.longPress600ms.map { String($0) } ?? ""].map(q).joined(separator: ",") }.joined(separator: "\n")
                try (header + rows + "\n").write(to: url, atomically: true, encoding: .utf8)
            } else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(ExportData(events: events, manualResults: results)).write(to: url, options: .atomic)
            }
            note = "已导出 \(events.count) 条事件"
        } catch { note = "导出失败：\(error.localizedDescription)" }
    }
}
