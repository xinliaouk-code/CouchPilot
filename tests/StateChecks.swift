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
        precondition(RadialAction.grid == [
            [.settings, .running, .inputMode], [.browser, nil, .favorites], [.finder, .pause, .previous]
        ])
        let positions = [(0, 1), (0, 2), (1, 2), (2, 2), (2, 1), (2, 0), (1, 0), (0, 0)]
        for (direction, position) in positions.enumerated() {
            precondition(RadialAction.grid[position.0][position.1]?.rawValue == direction)
        }
        for display in [CGSize(width: 1920, height: 1080), CGSize(width: 960, height: 540),
                        CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)] {
            for scale in [1.0, 1.25, 1.5] {
                let window = RadialDesign.windowSize(preferredPanelWidth: 520 * scale, available: display)
                precondition(window.width <= display.width + 0.001 && window.height <= display.height + 0.001)
            }
        }
        print("PASS: HUD grid maps all eight directions and fits scaled screen bounds")
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
        var desktopGate = DesktopInputGate()
        let offCenter = CGPoint(x: 0.8, y: 0)
        let transition = desktopGate.accept(actions: [.leftClick], cursor: .zero, scroll: offCenter, deadzone: 0.14)
        precondition(transition.actions.isEmpty && transition.scroll == .zero)
        let firstMove = desktopGate.accept(actions: [.leftClick], cursor: offCenter, scroll: offCenter, deadzone: 0.14)
        precondition(firstMove.cursor == offCenter && firstMove.scroll == .zero && firstMove.actions.isEmpty)
        _ = desktopGate.accept(actions: [], cursor: offCenter, scroll: .zero, deadzone: 0.14)
        let freshInput = desktopGate.accept(actions: [.leftClick], cursor: offCenter, scroll: offCenter, deadzone: 0.14)
        precondition(freshInput.actions == [.leftClick] && freshInput.scroll == offCenter)
        print("PASS: desktop mode observes neutral input independently without forwarding a held click")
        let tuning = MouseTuning()
        precondition(tuning.velocity(CGPoint(x: 0.1, y: 0.05), multiplier: 1) == .zero)
        precondition(tuning.velocity(CGPoint(x: 0, y: 1), multiplier: 1).y == -tuning.maximum)
        var buttons = MouseButtons()
        precondition(buttons.update([.leftClick]).first?.0 == .leftMouseDown)
        precondition(buttons.update([.leftClick]).isEmpty)
        precondition(buttons.movement().0 == .leftMouseDragged)
        precondition(buttons.update([.rightClick]).map { $0.0 } == [.leftMouseUp, .rightMouseDown])
        precondition(buttons.update([]).map { $0.0 } == [.rightMouseUp])
        precondition(buttons.update([]).isEmpty)
        var taps = ChordTapGate()
        let reserved: Set<String> = ["LB", "RB", "Menu"]
        precondition(taps.update([], reserved: reserved) == nil)
        precondition(taps.update(["LB"], reserved: reserved) == nil)
        precondition(taps.update([], reserved: reserved) == "LB")
        precondition(taps.update(["RB"], reserved: reserved) == nil)
        precondition(taps.update(reserved, reserved: reserved) == nil)
        precondition(taps.update(["RB"], reserved: reserved) == nil)
        precondition(taps.update([], reserved: reserved) == nil)
        print("PASS: individual shoulder tap works without emitting a page action for the radial chord")
        var mapping = DesktopMapping()
        precondition(mapping.actions(for: ["LT", "RT"], reserved: []) == [.precision, .boost])
        precondition(mapping.actions(for: ["A", "B"], reserved: ["A"]) == [.escape])
        mapping[.rightClick] = "A"
        precondition(mapping[.leftClick] == nil)
        precondition(mapping.actions(for: ["A"], reserved: []) == [.rightClick])
        mapping[.rightClick] = nil
        precondition(mapping.actions(for: ["A"], reserved: []).isEmpty)
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
        let chord: Set<String> = ["LB", "RB", "Menu"]
        triggers.update(pressed: [], tick: epoch)
        triggers.update(pressed: ["Home"], tick: epoch + 1_000_000)
        triggers.update(pressed: [], tick: epoch + 701_000_000)
        precondition(sources.isEmpty, "Home does not open the menu by default")
        triggers.update(pressed: chord, tick: epoch + 702_000_000)
        triggers.update(pressed: chord, tick: epoch + 1_302_000_000)
        precondition(sources == ["Controller chord"], "default chord opens the menu")
        print("PASS: default chord opens the menu, Home requires opt-in")
        sources.removeAll()
        triggers.homeEnabled = true
        triggers.holdMS = 400
        triggers.update(pressed: [], tick: epoch)
        for index in 0..<30 {
            let start = epoch + UInt64(index + 1) * 2_000_000_000
            let keys: Set<String> = index.isMultiple(of: 2) ? ["Home"] : ["LB", "RB", "Menu"]
            let duration: UInt64 = 400_000_000
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
        print("PASS integration: 30 alternating Home and chord cycles at the shared 400ms threshold")

        let suite = "CouchPilot.StateChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("cannot create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.radialHoldMS = 400
        store.value.startInMouse = true
        store.value.mouse.scroll = 400
        store.value.display = 42
        store.value.combo = ["LB", "X", "L3"]
        // Emulate the prior on-disk shape, with different Home and combo times.
        let data = defaults.data(forKey: "pilotSettings")!
        var legacy = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(legacy["homeMS"] as? Int == 400)
        legacy["comboMS"] = 700
        defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: "pilotSettings")
        let restored = SettingsStore(defaults: defaults)
        precondition(restored.value.radialHoldMS == 400)
        precondition(restored.value == store.value)
        precondition(!restored.value.homeOpensRadial, "old settings keep their values and use the default chord")
        restored.value.homeOpensRadial = true
        precondition(SettingsStore(defaults: defaults).value.homeOpensRadial)
        precondition(restored.value.desktopMapping == DesktopMapping())
        restored.value.desktopMapping[.leftClick] = "L3"
        restored.value.desktopMapping.swapSticks = true
        let savedMapping = SettingsStore(defaults: defaults).value.desktopMapping
        precondition(savedMapping[.leftClick] == "L3" && savedMapping.swapSticks)
        print("PASS: desktop defaults, reassignment, chord priority and persistence")
        print("PASS E: independent settings store restores trigger, mode, display and mouse values")
        print("PASS A: initial hold, exact threshold, duplicate input, short press")
    }
}
