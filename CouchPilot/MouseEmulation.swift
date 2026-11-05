import AppKit
import ApplicationServices
import Carbon

enum DesktopAction: String, Codable, CaseIterable, Identifiable {
    case leftClick, rightClick, precision, boost, escape, enter, altTab, missionControl, pageUp, pageDown, tab
    case arrowUp, arrowDown, arrowLeft, arrowRight

    var id: Self { self }

    var label: String {
        switch self {
        case .leftClick: return "左键（按住可拖动）"
        case .rightClick: return "右键"
        case .precision: return "按住减速"
        case .boost: return "按住加速"
        case .escape: return "Esc"
        case .enter: return "回车"
        case .altTab: return "按住 AltTab 窗口切换"
        case .missionControl: return "调度中心（⌃↑）"
        case .pageUp: return "向上翻页"
        case .pageDown: return "向下翻页"
        case .tab: return "Tab（下一焦点）"
        case .arrowUp: return "方向键 ↑"
        case .arrowDown: return "方向键 ↓"
        case .arrowLeft: return "方向键 ←"
        case .arrowRight: return "方向键 →"
        }
    }
    var keyCode: CGKeyCode? {
        switch self {
        case .escape: return CGKeyCode(kVK_Escape)
        case .enter: return CGKeyCode(kVK_Return)
        case .missionControl, .arrowUp: return CGKeyCode(kVK_UpArrow)
        case .pageUp: return CGKeyCode(kVK_PageUp)
        case .pageDown: return CGKeyCode(kVK_PageDown)
        case .tab: return CGKeyCode(kVK_Tab)
        case .arrowDown: return CGKeyCode(kVK_DownArrow)
        case .arrowLeft: return CGKeyCode(kVK_LeftArrow)
        case .arrowRight: return CGKeyCode(kVK_RightArrow)
        default: return nil
        }
    }

}

struct DesktopMapping: Codable, Equatable {
    static let buttons = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "L3", "R3",
                          "Up", "Down", "Left", "Right", "Menu", "Options"]
    static func label(for button: String) -> String {
        switch button {
        case "LB": return "L1 / LB"
        case "RB": return "R1 / RB"
        case "LT": return "L2 / LT"
        case "RT": return "R2 / RT"
        case "Menu": return "Start / Menu"
        default: return button
        }
    }

    private static let legacy: [DesktopAction: String] = [
        .leftClick: "A", .rightClick: "B", .precision: "LT", .boost: "RT", .escape: "X", .enter: "Y"
    ]
    private var bindings: [DesktopAction: String] = [
        .leftClick: "A", .escape: "B", .altTab: "X", .missionControl: "Y",
        .pageUp: "LB", .pageDown: "RB", .precision: "LT", .boost: "RT",
        .enter: "L3", .rightClick: "R3", .tab: "Options",
        .arrowUp: "Up", .arrowDown: "Down", .arrowLeft: "Left", .arrowRight: "Right"
    ]

    var upgraded: Self {
        guard bindings == Self.legacy else { return self }
        var value = Self()
        value.swapSticks = swapSticks
        return value
    }
    var swapSticks = false

    subscript(action: DesktopAction) -> String? {
        get { bindings[action] }
        set {
            if let newValue { bindings = bindings.filter { $0.value != newValue } }
            bindings[action] = newValue
        }
    }

    func actions(for pressed: Set<String>, reserved: Set<String>) -> Set<DesktopAction> {
        Set(bindings.compactMap { action, button in
            pressed.contains(button) && !reserved.contains(button) ? action : nil
        })
    }
}

// A single shoulder tap can flip a page, but a multi-button chord consumes
// every participating key until all of them have been released.
struct ChordTapGate {
    private var pending: String?
    private var blocked = true

    mutating func update(_ physical: Set<String>, reserved: Set<String>) -> String? {
        let down = physical.intersection(reserved)
        if down.isEmpty {
            defer { pending = nil; blocked = false }
            return blocked ? nil : pending
        }
        if down.count > 1 || (pending != nil && pending != down.first) {
            pending = nil
            blocked = true
        } else if !blocked {
            pending = down.first
        }
        return nil
    }
}

struct MouseTuning: Codable, Equatable {
    var deadzone = 0.14
    var sensitivity = 1.0
    var maximum = 1850.0
    var acceleration = 1.7
    var fine = 0.12
    var scroll = 650.0
    var restrict = false

    func velocity(_ point: CGPoint, multiplier: Double) -> CGPoint {
        let magnitude = hypot(point.x, point.y)
        guard magnitude > deadzone else { return .zero }
        let amount = (min(magnitude, 1) - deadzone) / (1 - deadzone)
        let speed = min(maximum, maximum * sensitivity * pow(amount, acceleration)) * multiplier
        return CGPoint(x: point.x / magnitude * speed, y: -point.y / magnitude * speed)
    }
}

struct MouseButtons {
    enum LeftState { case idle, down, dragging }
    private(set) var left = LeftState.idle
    private(set) var right = false

    mutating func update(_ held: Set<DesktopAction>) -> [(CGEventType, CGMouseButton)] {
        var events: [(CGEventType, CGMouseButton)] = []
        if held.contains(.leftClick), left == .idle {
            left = .down
            events.append((.leftMouseDown, .left))
        } else if !held.contains(.leftClick), left != .idle {
            left = .idle
            events.append((.leftMouseUp, .left))
        }
        if held.contains(.rightClick) != right {
            right.toggle()
            events.append((right ? .rightMouseDown : .rightMouseUp, .right))
        }
        return events
    }

    mutating func movement() -> (CGEventType, CGMouseButton) {
        if left != .idle { left = .dragging; return (.leftMouseDragged, .left) }
        if right { return (.rightMouseDragged, .right) }
        return (.mouseMoved, .left)
    }
}

struct DesktopInputGate {
    private var buttonsReady = false
    private var cursorReady = false
    private var scrollReady = false

    mutating func accept(actions: Set<DesktopAction>, cursor: CGPoint, scroll: CGPoint, deadzone: Double)
        -> (actions: Set<DesktopAction>, cursor: CGPoint, scroll: CGPoint) {
        if actions.isEmpty { buttonsReady = true }
        if hypot(cursor.x, cursor.y) <= deadzone { cursorReady = true }
        if hypot(scroll.x, scroll.y) <= deadzone { scrollReady = true }
        return (buttonsReady ? actions : [], cursorReady ? cursor : .zero, scrollReady ? scroll : .zero)
    }
}

@MainActor
final class MouseEmulationEngine {
    var tuning = MouseTuning()
    var mapping = DesktopMapping() {
        didSet { if oldValue != mapping { suspend() } }
    }
    var display: UInt32 = 0
    var onError: ((String) -> Void)?
    var onPermissionChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var buttons = MouseButtons()
    private var held: Set<DesktopAction> = []
    private var gate = DesktopInputGate()
    private var chordTaps = ChordTapGate()
    private var switchingWindows = false
    private var ownsOption = false
    private var suppressedClicks: Set<DesktopAction> = []
    private var trusted = false
    private var stopped = false
    private var left = CGPoint.zero
    private var right = CGPoint.zero
    private var velocity = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private var lastTick = 0.0
    private var lastPermissionCheck = 0.0
    private var reportedPermissionFailure = false
    private let source = CGEventSource(stateID: .hidSystemState)

    func recheck() -> Bool {
        stopped = false
        return updatePermission()
    }

    private func updatePermission() -> Bool {
        let previouslyTrusted = trusted
        trusted = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        if trusted != previouslyTrusted { onPermissionChange?(trusted) }
        if trusted { reportedPermissionFailure = false }
        return trusted
    }

    /// Observe the state already known at a mode transition without posting input.
    func prime(_ physicalButtons: Set<String>, reserved: Set<String>, left: CGPoint, right: CGPoint) {
        _ = chordTaps.update(physicalButtons, reserved: reserved)
        _ = filter(physicalButtons, reserved: reserved, left: left, right: right)
    }

    private func filter(_ physicalButtons: Set<String>, reserved: Set<String>, left: CGPoint, right: CGPoint)
        -> (actions: Set<DesktopAction>, cursor: CGPoint, scroll: CGPoint) {
        gate.accept(actions: mapping.actions(for: physicalButtons, reserved: reserved),
                    cursor: mapping.swapSticks ? right : left, scroll: mapping.swapSticks ? left : right,
                    deadzone: tuning.deadzone)
    }

    func consume(_ physicalButtons: Set<String>, reserved: Set<String>, left: CGPoint, right: CGPoint) {
        guard !stopped, checkPermission() else { return }
        let (pressed, cursorStick, scrollStick) = filter(physicalButtons, reserved: reserved, left: left, right: right)
        var edges = pressed.subtracting(held)
        if let tap = chordTaps.update(physicalButtons, reserved: reserved) {
            for action in [DesktopAction.pageUp, .pageDown] where mapping[action] == tap {
                edges.insert(action)
            }
        }
        let moving = hypot(cursorStick.x, cursorStick.y) > tuning.deadzone || hypot(scrollStick.x, scrollStick.y) > tuning.deadzone
        held = pressed
        self.left = cursorStick
        self.right = scrollStick
        let previouslySwitching = switchingWindows
        if edges.contains(.altTab) { beginWindowSwitch() }
        let wasSwitching = previouslySwitching || switchingWindows
        if wasSwitching {
            suppressedClicks.formUnion(pressed.intersection([.leftClick, .rightClick]))
            if edges.contains(.escape) { endWindowSwitch(cancel: true) }
            else if !pressed.contains(.altTab) || edges.contains(.leftClick) || edges.contains(.enter) { endWindowSwitch(cancel: false) }
        }
        suppressedClicks.formIntersection(pressed)
        for (type, button) in buttons.update(held.subtracting(suppressedClicks)) {
            guard postMouse(type, button: button) else { fail("无法创建鼠标事件。"); return }
        }
        for action in DesktopAction.allCases where edges.contains(action) {
            if wasSwitching && ![DesktopAction.arrowUp, .arrowDown, .arrowLeft, .arrowRight].contains(action) { continue }
            guard let code = action.keyCode else { continue }
            let flags: CGEventFlags = action == .missionControl ? .maskControl : (switchingWindows ? .maskAlternate : [])
            guard postKey(code, flags: flags) else { fail("无法发送桌面按键。"); return }
        }
        let active = moving || buttons.left != .idle || buttons.right || switchingWindows
        if active, timer == nil {
            lastTick = ProcessInfo.processInfo.systemUptime
            let work = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            timer = work
            RunLoop.main.add(work, forMode: .common)
        } else if !active {
            stopTimer()
        }
    }

    func suspend() {
        stopTimer()
        endWindowSwitch(cancel: true)
        chordTaps = ChordTapGate()
        suppressedClicks.removeAll()
        for (type, button) in buttons.update([]) { _ = postMouse(type, button: button) }
        gate = DesktopInputGate()
        held = []
        left = .zero
        right = .zero
    }

    private func fail(_ message: String) {
        suspend()
        stopped = true
        onError?(message)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        velocity = .zero
        scrollRemainder = .zero
    }

    private func checkPermission() -> Bool {
        if ProcessInfo.processInfo.systemUptime - lastPermissionCheck >= 0.5 {
            _ = updatePermission()
        }
        if !trusted && !reportedPermissionFailure {
            suspend()
            reportedPermissionFailure = true
            onError?("桌面模式等待辅助功能授权。请在设置的指针页重新检查。")
        }
        return trusted
    }

    private func step() {
        guard checkPermission() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, now - lastTick)
        lastTick = now
        let multiplier = held.contains(.precision) ? tuning.fine : (held.contains(.boost) ? 1.65 : 1)
        let target = tuning.velocity(left, multiplier: multiplier)
        if target != .zero, let cursor = CGEvent(source: nil)?.location {
            let blend = 1 - exp(-dt * 48)
            velocity.x += (target.x - velocity.x) * blend
            velocity.y += (target.y - velocity.y) * blend
            let next = CGPoint(x: cursor.x + velocity.x * dt, y: cursor.y + velocity.y * dt)
            let (type, button) = buttons.movement()
            guard postMouse(type, button: button, point: clamp(next)) else { fail("无法移动光标。"); return }
        } else { velocity = .zero }
        if hypot(right.x, right.y) > tuning.deadzone {
            scrollRemainder.x -= right.x * tuning.scroll * dt
            scrollRemainder.y += right.y * tuning.scroll * dt
            let x = Int32(scrollRemainder.x), y = Int32(scrollRemainder.y)
            if x != 0 || y != 0 {
                scrollRemainder.x -= CGFloat(x)
                scrollRemainder.y -= CGFloat(y)
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                          wheel1: y, wheel2: x, wheel3: 0) else { fail("无法创建滚动事件。"); return }
                event.post(tap: .cghidEventTap)
            }
        } else { scrollRemainder = .zero }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let screens = tuning.restrict ? [DisplayManager.screen(preferred: display)].compactMap { $0 } : NSScreen.screens
        let candidates = screens.map { screen -> CGPoint in
            let frame = CGDisplayBounds(DisplayManager.id(screen))
            return CGPoint(x: min(max(point.x, frame.minX), frame.maxX - 1),
                           y: min(max(point.y, frame.minY), frame.maxY - 1))
        }
        return candidates.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, point: CGPoint? = nil) -> Bool {
        guard let point = point ?? CGEvent(source: nil)?.location,
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func beginWindowSwitch() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.lwouis.alt-tab-macos").isEmpty else {
            onError?("请先启动 AltTab，并将其快捷键设为 Option + Tab。")
            return
        }
        if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            guard setOption(down: true) else { return }
            ownsOption = true
        }
        switchingWindows = true
        if !postKey(CGKeyCode(kVK_Tab), flags: .maskAlternate) { endWindowSwitch(cancel: true) }
    }

    private func endWindowSwitch(cancel: Bool) {
        guard switchingWindows else { return }
        if cancel { _ = postKey(CGKeyCode(kVK_Escape), flags: .maskAlternate) }
        if ownsOption { _ = setOption(down: false) }
        ownsOption = false
        switchingWindows = false
    }

    private func setOption(down: Bool) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Option), keyDown: down) else { return false }
        event.type = .flagsChanged
        var flags = CGEventSource.flagsState(.combinedSessionState)
        if down { flags.insert(.maskAlternate) } else { flags.remove(.maskAlternate) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
