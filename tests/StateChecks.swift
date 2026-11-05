import Foundation
import CoreGraphics

@main
struct StateChecks {
    @MainActor static func main() {
        var gate = HoldGate()
        gate.update(held: true, at: 0)
        precondition(!gate.fire(at: 900_000_000, after: 600), "ignore initial held state")
        gate.update(held: false, at: 900_000_000)
        gate.update(held: true, at: 1_000_000_000)
        gate.update(held: true, at: 1_200_000_000)
        precondition(!gate.fire(at: 1_599_999_999, after: 600))
        precondition(gate.fire(at: 1_600_000_000, after: 600))
        precondition(!gate.fire(at: 2_000_000_000, after: 600))
        gate.update(held: false, at: 2_000_000_000)
        gate.update(held: true, at: 2_100_000_000)
        gate.update(held: false, at: 2_200_000_000)
        precondition(!gate.fire(at: 3_000_000_000, after: 600), "short press")
        var wheel = RadialSelection()
        wheel.update(CGPoint(x: 1, y: 0))
        precondition(wheel.selected == nil)
        wheel.update(.zero)
        for action in RadialAction.allCases {
            let angle = Double(action.rawValue) * .pi / 4
            wheel.update(CGPoint(x: sin(angle), y: cos(angle)))
            precondition(wheel.selected == action)
        }
        let nearBoundary = -.pi / 8 + Double.pi / 180
        wheel.update(CGPoint(x: sin(nearBoundary), y: cos(nearBoundary)))
        wheel.update(.zero)
        precondition(wheel.selected == .settings, "retain selection and resist boundary jitter")
        let tuning = MouseTuning()
        precondition(tuning.velocity(CGPoint(x: 0.1, y: 0.05), multiplier: 1) == .zero)
        precondition(tuning.velocity(CGPoint(x: 0, y: 1), multiplier: 1).y == -tuning.maximum)
        var buttons = MouseButtons()
        precondition(buttons.update(["A"]).first?.0 == .leftMouseDown)
        precondition(buttons.update(["A"]).isEmpty)
        precondition(buttons.movement().0 == .leftMouseDragged)
        precondition(buttons.update(["B"]).map { $0.0 } == [.leftMouseUp, .rightMouseDown])
        precondition(buttons.update([]).map { $0.0 } == [.rightMouseUp])
        precondition(buttons.update([]).isEmpty)
        var history = AppRecency()
        [11, 22, 33, 22].forEach { history.activated(pid_t($0)) }
        precondition(history.order == [22, 33, 11])
        precondition(history.current == 22 && history.previous == 33)
        history.terminated(33)
        precondition(history.previous == 11)
        print("PASS D: MRU order, repeat activation, previous and terminated apps")
        print("PASS C: deadzone, velocity, drag transitions and idempotent release")
        print("PASS B: all directions, initial recenter, hysteresis, retained selection")
        let triggers = TriggerManager()
        var sources: [String] = []
        triggers.fire = { sources.append($0) }
        let epoch = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        triggers.update(pressed: [], tick: epoch)
        for index in 0..<30 {
            let start = epoch + UInt64(index + 1) * 2_000_000_000
            let keys: Set<String> = index.isMultiple(of: 2) ? ["Home"] : ["LB", "RB", "Menu"]
            let duration: UInt64 = index.isMultiple(of: 2) ? 600_000_000 : 700_000_000
            triggers.update(pressed: keys, tick: start)
            triggers.update(pressed: keys, tick: start + duration - 1)
            precondition(sources.count == index)
            triggers.update(pressed: keys, tick: start + duration)
            triggers.update(pressed: keys, tick: start + duration + 100_000_000)
            triggers.update(pressed: [], tick: start + duration + 200_000_000)
            precondition(sources.count == index + 1)
            precondition(sources.last == (index.isMultiple(of: 2) ? "Home" : "Controller chord"))
        }
        triggers.reset()
        print("PASS integration: 30 alternating Home and chord cycles, one trigger per hold")

        let suite = "CouchPilot.StateChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("cannot create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.homeMS = 800
        store.value.startInMouse = true
        store.value.mouse.scroll = 400
        store.value.display = 42
        store.value.combo = ["LB", "X", "L3"]
        let restored = SettingsStore(defaults: defaults)
        precondition(restored.value == store.value)
        print("PASS E: independent settings store restores trigger, mode, display and mouse values")
        print("PASS A: initial hold, exact threshold, duplicate input, short press")
    }
}
