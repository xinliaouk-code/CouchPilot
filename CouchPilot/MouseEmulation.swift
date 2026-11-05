import AppKit
import ApplicationServices
import Carbon

struct MouseTuning: Codable, Equatable {
    var deadzone = 0.14
    var sensitivity = 1.0
    var maximum = 1850.0
    var acceleration = 1.7
    var fine = 0.30
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

    mutating func update(_ held: Set<String>) -> [(CGEventType, CGMouseButton)] {
        var events: [(CGEventType, CGMouseButton)] = []
        if held.contains("A"), left == .idle {
            left = .down
            events.append((.leftMouseDown, .left))
        } else if !held.contains("A"), left != .idle {
            left = .idle
            events.append((.leftMouseUp, .left))
        }
        if held.contains("B") != right {
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

@MainActor
final class MouseEmulationEngine {
    var tuning = MouseTuning()
    var display: UInt32 = 0
    var onError: ((String) -> Void)?
    private var timer: Timer?
    private var buttons = MouseButtons()
    private var held: Set<String> = []
    private var armed = false
    private var trusted = false
    private var stopped = false
    private var left = CGPoint.zero
    private var right = CGPoint.zero
    private var velocity = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private var lastTick = 0.0
    private var lastPermissionCheck = 0.0
    private let requiredNeutral: Set<String> = ["A", "B", "X", "Y"]
    private let source = CGEventSource(stateID: .hidSystemState)

    func recheck() -> Bool {
        trusted = AXIsProcessTrusted()
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        if trusted { stopped = false }
        return trusted
    }

    func consume(_ pressed: Set<String>, left: CGPoint, right: CGPoint) {
        guard !stopped else { return }
        if !armed {
            guard pressed.isDisjoint(with: requiredNeutral),
                  hypot(left.x, left.y) <= tuning.deadzone, hypot(right.x, right.y) <= tuning.deadzone else { return }
            guard recheck() else { fail("需要辅助功能权限。鼠标模拟已暂停。"); return }
            armed = true
        }
        let edges = pressed.subtracting(held)
        let moving = hypot(left.x, left.y) > tuning.deadzone || hypot(right.x, right.y) > tuning.deadzone
        if moving || !edges.isEmpty {
            guard checkPermission() else { return }
        }
        held = pressed
        self.left = left
        self.right = right
        for (type, button) in buttons.update(held) {
            guard postMouse(type, button: button) else { fail("无法创建鼠标事件。"); return }
        }
        if edges.contains("X"), !postKey(CGKeyCode(kVK_Escape)) { fail("无法创建 Escape 事件。"); return }
        if edges.contains("Y"), !postKey(CGKeyCode(kVK_Return)) { fail("无法创建 Enter 事件。"); return }
        let active = moving || buttons.left != .idle || buttons.right
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
        for (type, button) in buttons.update([]) { _ = postMouse(type, button: button) }
        armed = false
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
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 0.5 {
            trusted = AXIsProcessTrusted()
            lastPermissionCheck = now
        }
        if !trusted { fail("辅助功能权限不可用。鼠标模拟已暂停。") }
        return trusted
    }

    private func step() {
        guard checkPermission() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, now - lastTick)
        lastTick = now
        let multiplier = held.contains("LB") ? tuning.fine : (held.contains("RB") ? 1.65 : 1)
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

    private func postKey(_ code: CGKeyCode) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
