import Carbon
import Foundation

struct HoldGate {
    private var blocked = true
    private(set) var started: UInt64?
    private var fired = false

    mutating func reset() { self = HoldGate() }

    func deadline(after milliseconds: Int) -> UInt64? {
        guard !fired else { return nil }
        return started.map { $0 + UInt64(milliseconds) * 1_000_000 }
    }
    mutating func update(held: Bool, at tick: UInt64) {
        if !held {
            blocked = false
            started = nil
            fired = false
        } else if !blocked && started == nil {
            started = tick
        }
    }
    mutating func fire(at tick: UInt64, after milliseconds: Int) -> Bool {
        guard let started, !fired, tick >= started,
              tick - started >= UInt64(milliseconds) * 1_000_000 else { return false }
        fired = true
        return true
    }
}

final class TriggerManager {
    private var home = HoldGate()
    private var combo = HoldGate()
    private var timer: DispatchWorkItem?
    var homeEnabled = false { didSet { if oldValue != homeEnabled { reset() } } }
    var holdMS = 600 { didSet { if oldValue != holdMS { reset() } } }
    var combination: Set<String> = ["LB", "RB", "Menu"] {
        didSet { if oldValue != combination { reset() } }
    }
    var fire: ((String) -> Void)?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var keyboardDown = false

    func reset() {
        timer?.cancel()
        timer = nil
        home.reset()
        combo.reset()
    }

    func update(pressed: Set<String>, tick: UInt64) {
        let oldHome = home.started
        let oldCombo = combo.started
        // A release delivered after the threshold still completes the hold.
        completeHolds(at: tick)
        home.update(held: homeEnabled && pressed.contains("Home"), at: tick)
        combo.update(held: !combination.isEmpty && combination.isSubset(of: pressed), at: tick)
        if oldHome != home.started || oldCombo != combo.started { schedule() }
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        let deadlines = [home.deadline(after: holdMS), combo.deadline(after: holdMS)].compactMap { $0 }
        guard let deadline = deadlines.min() else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.completeHolds(at: DispatchTime.now().uptimeNanoseconds)
            self?.schedule()
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
    }

    private func completeHolds(at tick: UInt64) {
        let h = home.fire(at: tick, after: holdMS)
        let c = combo.fire(at: tick, after: holdMS)
        if h || c {
            reset()
            fire?(h ? "Home" : "Controller chord")
        }
    }

    func register(key: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x43505054, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<TriggerManager>.fromOpaque(data).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { manager.keyboardDown = false }
            else if !manager.keyboardDown {
                manager.keyboardDown = true
                manager.fire?("Keyboard")
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { return status }
        let registration = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x43505054, id: 1),
                                               target, 0, &hotKey)
        if registration != noErr { unregister() }
        return registration
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        keyboardDown = false
    }

    deinit { unregister() }
}
