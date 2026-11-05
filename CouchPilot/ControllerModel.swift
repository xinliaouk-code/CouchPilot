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

@MainActor
final class ControllerModel: ObservableObject {
    @Published var device = "未连接"
    @Published var profile = "—"
    @Published var homeInfo = "等待手柄"
    @Published private(set) var homeSystemAction = "尚未检查"
    @Published var buttons: [String: Float] = [:]
    @Published var left = CGPoint.zero
    @Published var right = CGPoint.zero
    @Published var events: [LogEvent] = []
    @Published var background = true {
        didSet {
            GCController.shouldMonitorBackgroundEvents = background
            if !background && NSApp?.isActive != true { cancelHomeDiagnostic() }
            log("setting", "backgroundMonitoring", String(background))
        }
    }
    @Published var gestureDisabled = false {
        didSet { applyGesture() }
    }
    @Published var results: [String: String] = UserDefaults.standard.dictionary(forKey: "manualResults") as? [String: String] ?? [:]
    @Published var note = ""
    var onInput: ((Set<String>, CGPoint, CGPoint, UInt64) -> Void)?
    var onDevice: ((Set<String>, Set<String>, CGPoint, CGPoint) -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var axisLog: [String: UInt64] = [:]
    private var controller: GCController?
    private let exclusiveInput = VaderExclusiveInput()
    private(set) var exclusiveActive = false
    private var exclusiveSeeded = false
    private var exclusiveWatchdog: Timer?
    private var lastExclusiveReport = 0.0
    var onExclusiveLoss: ((String) -> Void)?
    private var pressedStates: [String: Bool] = [:]
    private var homeDown: UInt64?
    private var homeTimer: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let clock = ISO8601DateFormatter()

    init() {
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if NSApp?.isActive != true && !self.background { self.cancelHomeDiagnostic() }
                    self.log("focus", "application", NSApp?.isActive == true ? "foreground" : "background")
                    self.onFocus?(NSApp?.isActive == true)
                }
            })
        }
        log("session", "launch", "diagnostics started")
        refresh()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func refresh() {
        guard !exclusiveActive else { return }
        let next = GCController.controllers().first
        if controller === next { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        cancelHomeDiagnostic()
        controller = next; buttons = [:]; pressedStates = [:]; left = .zero; right = .zero
        axisLog.removeAll()
        homeSystemAction = "尚未检查"
        defer { publishDevice() }
        guard let c = next else {
            device = "未连接"; profile = "—"; homeInfo = "未连接：无法判断 Home 是否暴露"; log("connection", "controller", "disconnected / none"); return
        }
        device = c.vendorName ?? "未知设备"
        profile = c.extendedGamepad != nil ? "Physical Input + Extended Gamepad" : "Physical Input；无 Extended Gamepad（此工具的输入视图不可用）"
        log("connection", "controller", "connected: \(device); \(profile)")
        guard let gamepad = c.extendedGamepad else { homeInfo = "无 Extended Gamepad，无法通过该 profile 读取 Home"; return }
        applyGesture()
        c.handlerQueue = .main
        gamepad.valueChangedHandler = { [weak self, weak c] gamepad, element in
            guard let self, let c else { return }
            // Snapshot values at callback time; UI and event mutations remain on the main queue.
            let lx = gamepad.leftThumbstick.xAxis.value, ly = gamepad.leftThumbstick.yAxis.value
            let rx = gamepad.rightThumbstick.xAxis.value, ry = gamepad.rightThumbstick.yAxis.value
            let pairs = Self.inputs(gamepad)
            let changed = pairs.map { ($0.0, $0.1.value, $0.1.isPressed) }
            let stick = element === gamepad.leftThumbstick ? "Left stick" : (element === gamepad.rightThumbstick ? "Right stick" : nil)
            let tick = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated {
                guard !self.exclusiveActive, self.controller === c, self.background || NSApp?.isActive == true else { return }
                let left = CGPoint(x: CGFloat(lx), y: CGFloat(ly)), right = CGPoint(x: CGFloat(rx), y: CGFloat(ry))
                if self.left != left { self.left = left }
                if self.right != right { self.right = right }
                if let stick, tick >= (self.axisLog[stick] ?? 0) + 100_000_000 {
                    self.axisLog[stick] = tick
                    self.log("axis", stick, stick == "Left stick" ? "\(lx),\(ly)" : "\(rx),\(ry)", tick: tick) }
                for (name, value, pressed) in changed { self.updateButton(name, value: value, pressed: pressed, tick: tick) }
                self.onInput?(self.held, self.left, self.right, tick)
            }
        }
    }
    nonisolated private static func inputs(_ gamepad: GCExtendedGamepad) -> [(String, GCControllerButtonInput)] {
        return [("A",gamepad.buttonA),("B",gamepad.buttonB),("X",gamepad.buttonX),("Y",gamepad.buttonY),("LB",gamepad.leftShoulder),("RB",gamepad.rightShoulder),("LT",gamepad.leftTrigger),("RT",gamepad.rightTrigger),("Up",gamepad.dpad.up),("Down",gamepad.dpad.down),("Left",gamepad.dpad.left),("Right",gamepad.dpad.right)] + [("Menu", gamepad.buttonMenu)] + (gamepad.buttonOptions.map { [("Options", $0)] } ?? []) + (gamepad.leftThumbstickButton.map { [("L3", $0)] } ?? []) + (gamepad.rightThumbstickButton.map { [("R3", $0)] } ?? []) + (gamepad.buttonHome.map { [("Home", $0)] } ?? [])
    }

    private var held: Set<String> { Set(pressedStates.filter { $0.value }.keys) }

    func beginExclusive() throws {
        guard !exclusiveActive else { return }
        exclusiveInput.onReport = { [weak self] in self?.receiveExclusive($0) }
        exclusiveInput.onLoss = { [weak self] in self?.loseExclusive("Vader 4 Pro 接收器已断开。") }
        try exclusiveInput.open()
        exclusiveActive = true
        exclusiveSeeded = false
        cancelHomeDiagnostic()
        device = "Flydigi VADER4"
        profile = "Vader 4 Pro USB · HID 独占"
        homeInfo = "从 USB 报告读取 Home，系统手势偏好适用于共享手柄模式。"
        log("connection", "HID", "exclusive open")
        lastExclusiveReport = ProcessInfo.processInfo.systemUptime
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkExclusiveReports() }
        }
        exclusiveWatchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private func checkExclusiveReports() {
        let elapsed = ProcessInfo.processInfo.systemUptime - lastExclusiveReport
        if !exclusiveSeeded && elapsed >= 5 {
            loseExclusive("独占后未收到可识别的手柄报告。")
        } else if exclusiveSeeded && elapsed >= 0.75 &&
                    (!held.isEmpty || hypot(left.x, left.y) > 0.04 || hypot(right.x, right.y) > 0.04) {
            loseExclusive("手柄在按键或摇杆未回中时停止发送报告，已释放独占。")
        }
    }

    func endExclusive() {
        guard exclusiveActive else { return }
        exclusiveWatchdog?.invalidate()
        exclusiveWatchdog = nil
        exclusiveInput.close()
        exclusiveActive = false
        exclusiveSeeded = false
        cancelHomeDiagnostic()
        log("connection", "HID", "exclusive close")
        let previous = controller
        refresh()
        if previous === controller {
            profile = controller?.extendedGamepad != nil ? "Physical Input + Extended Gamepad" : "—"
            device = controller?.vendorName ?? "未连接"
            if controller == nil { homeInfo = "未连接：无法判断 Home 是否暴露" }
            else { applyGesture() }
            publishDevice()
        }
    }

    private func loseExclusive(_ reason: String) {
        endExclusive()
        onExclusiveLoss?(reason)
    }

    private func receiveExclusive(_ report: VaderInputReport) {
        guard exclusiveActive else { return }
        lastExclusiveReport = ProcessInfo.processInfo.systemUptime
        let tick = DispatchTime.now().uptimeNanoseconds
        let leftChanged = left != report.left
        let rightChanged = right != report.right
        if leftChanged { left = report.left }
        if rightChanged { right = report.right }
        if !exclusiveSeeded {
            exclusiveSeeded = true
            buttons = report.values
            pressedStates = report.values.mapValues { $0 > 0.5 }
            onDevice?(Set(VaderInputReport.buttons), held, left, right)
            return
        }
        if leftChanged, tick >= (axisLog["Left stick"] ?? 0) + 100_000_000 {
            axisLog["Left stick"] = tick
            log("axis", "Left stick", "\(left.x),\(left.y)", tick: tick)
        }
        if rightChanged, tick >= (axisLog["Right stick"] ?? 0) + 100_000_000 {
            axisLog["Right stick"] = tick
            log("axis", "Right stick", "\(right.x),\(right.y)", tick: tick)
        }
        let changedButtons = report.values.filter { buttons[$0.key] != $0.value }
        guard leftChanged || rightChanged || !changedButtons.isEmpty else { return }
        for (name, value) in changedButtons {
            updateButton(name, value: value, pressed: value > 0.5, tick: tick)
        }
        onInput?(held, left, right, tick)
    }

    func publishDevice() {
        if exclusiveActive {
            if exclusiveSeeded { onDevice?(Set(VaderInputReport.buttons), held, left, right) }
            return
        }
        guard let gamepad = controller?.extendedGamepad else { onDevice?([], [], .zero, .zero); return }
        let inputs = Self.inputs(gamepad)
        pressedStates = Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, $0.1.isPressed) })
        buttons = Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, $0.1.value) })
        left = CGPoint(x: CGFloat(gamepad.leftThumbstick.xAxis.value), y: CGFloat(gamepad.leftThumbstick.yAxis.value))
        right = CGPoint(x: CGFloat(gamepad.rightThumbstick.xAxis.value), y: CGFloat(gamepad.rightThumbstick.yAxis.value))
        onDevice?(Set(inputs.map { $0.0 }), held, left, right)
    }

    func cancelHomeDiagnostic() {
        homeTimer?.cancel()
        homeTimer = nil
        homeDown = nil
    }

    @available(macOS 27.0, *)
    func openHomeSystemSettings() {
        guard controller != nil else { return }
        do {
            try GCControllerHomeButtonSettingsManager().openControllerHomeButtonSettings(for: .customizeSystemAction)
        } catch {
            homeSystemAction = "无法打开系统设置：\(error.localizedDescription)"
            log("error", "Home system action", homeSystemAction)
        }
    }

    @available(macOS 27.0, *)
    func checkHomeSystemAction() {
        guard controller != nil else { return }
        do {
            let action = try GCControllerHomeButtonSettingsManager().controllerHomeButtonSystemAction.action
            switch action {
            case .disabled: homeSystemAction = "已关闭"
            case .other: homeSystemAction = "系统报告有其他 Home 动作，请在系统设置查看具体动作"
            case .openCurrentApplication: homeSystemAction = "打开当前应用"
            case .unavailable: homeSystemAction = "系统未提供设置状态"
            @unknown default: homeSystemAction = "未知状态"
            }
        } catch {
            homeSystemAction = "无法读取系统状态，请在系统设置查看"
        }
        log("setting", "Home system action", homeSystemAction)
    }

    func applyGesture() {
        guard !exclusiveActive, let controller else { return }
        let physicalHome = controller.physicalInputProfile.buttons[GCInputButtonHome]
        let extendedHome = controller.extendedGamepad?.buttonHome
        let preference: GCControllerElement.SystemGestureState = gestureDisabled ? .disabled : .enabled
        physicalHome?.preferredSystemGestureState = preference
        if extendedHome !== physicalHome { extendedHome?.preferredSystemGestureState = preference }
        guard let home = extendedHome else {
            homeInfo = "Extended Gamepad 未暴露 Home；物理映射：\(physicalHome == nil ? "未暴露" : "已暴露")。当前轮盘读取 Extended Gamepad 输入。"
            log("setting", "Home gesture", homeInfo)
            return
        }
        homeInfo = "buttonHome 已暴露 · isBoundToSystemGesture: \(home.isBoundToSystemGesture) · preferred: \(home.preferredSystemGestureState == .disabled ? "disabled" : "enabled")（系统不保证遵从）"
        log("setting", "Home gesture", homeInfo)
    }
    func updateButton(_ name: String, value: Float, pressed: Bool, tick: UInt64) {
        let wasPressed = pressedStates[name] ?? false
        pressedStates[name] = pressed
        if buttons[name] != value { buttons[name] = value }
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
        events.append(LogEvent(timestamp: clock.string(from: Date()), uptimeMilliseconds: Double(tick) / 1_000_000, device: device, appState: NSApp?.isActive == true ? "foreground" : "background", backgroundMonitoring: background, type: type, input: input, value: value, durationMilliseconds: duration, longPress600ms: long))
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
