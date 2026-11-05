import Foundation

// Compile with ControllerModel.swift, VaderExclusiveInput.swift and TriggerManager.swift.
// This opens only the matching gamepad interface, posts no desktop events and creates no window.
@main struct VaderExclusiveProbe {
    @MainActor static func main() throws {
        let model = ControllerModel()
        let trigger = TriggerManager()
        var seeded = false
        var radialTriggered = false
        trigger.fire = { source in radialTriggered = source == "Controller chord" }
        model.onDevice = { inputs, held, _, _ in
            guard model.exclusiveActive else { return }
            seeded = inputs.isSuperset(of: ["LB", "RB", "Menu"])
            trigger.update(pressed: held, tick: DispatchTime.now().uptimeNanoseconds)
        }
        model.onInput = { held, _, _, tick in trigger.update(pressed: held, tick: tick) }
        let checkChord = CommandLine.arguments.contains("--chord")
        try model.beginExclusive()
        defer { model.endExclusive() }
        if CommandLine.arguments.contains("--exit-while-owned") { exit(0) }
        if checkChord {
            FileHandle.standardOutput.write(Data("READY: hold L1 + R1 + Start.\n".utf8))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + (checkChord ? 35 : 6)
        while model.exclusiveActive && ProcessInfo.processInfo.systemUptime < deadline
                && !(seeded && (!checkChord || radialTriggered)) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.10))
        }
        model.endExclusive()
        trigger.reset()
        guard seeded, !checkChord || radialTriggered else {
            print("FAIL: seeded=\(seeded), chord=\(radialTriggered)")
            exit(1)
        }
        precondition(!model.exclusiveActive)
        let contender = VaderExclusiveInput()
        try contender.open()
        contender.close()
        print("PASS: production model received live exclusive reports and released for an independent open")
        if checkChord { print("PASS: production TriggerManager fired the controller chord") }
    }
}
