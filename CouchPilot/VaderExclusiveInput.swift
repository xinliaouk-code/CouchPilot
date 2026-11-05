import Foundation
import IOKit.hid

struct VaderInputReport {
    static let buttons = ["A", "B", "X", "Y", "LB", "RB", "L3", "R3", "Menu", "Options",
                          "Home", "Up", "Down", "Left", "Right", "LT", "RT"]
    let values: [String: Float]
    let left: CGPoint
    let right: CGPoint

    var pressed: Set<String> { Set(values.filter { $0.value > 0.5 }.keys) }

    init?(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard bytes.count == 20 else { return nil }
        let low = ["Up", "Down", "Left", "Right", "Menu", "Options", "L3", "R3"]
        let high = ["LB", "RB", "Home", "", "A", "B", "X", "Y"]
        var values: [String: Float] = [:]
        for (byte, names) in [(bytes[2], low), (bytes[3], high)] {
            for (bit, name) in names.enumerated() where !name.isEmpty {
                values[name] = byte & (1 << bit) == 0 ? 0 : 1
            }
        }
        values["LT"] = Float(bytes[4]) / 255
        values["RT"] = Float(bytes[5]) / 255
        func axis(_ offset: Int) -> CGFloat {
            let value = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            return max(-1, CGFloat(value) / 32767)
        }
        left = CGPoint(x: axis(6), y: axis(8))
        right = CGPoint(x: axis(10), y: axis(12))
        self.values = values
    }
}

@MainActor
final class VaderExclusiveInput {
    enum OpenError: LocalizedError {
        case noExactMatch, ownership(IOReturn)
        var errorDescription: String? {
            switch self {
            case .noExactMatch: return "未找到唯一且报告格式匹配的 Vader 4 Pro USB 手柄接口。"
            case .ownership(let result):
                return String(format: "无法独占 Vader 4 Pro，IOKit 返回 0x%08x。", UInt32(bitPattern: result))
            }
        }
    }

    // The Xbox360Gamepad descriptor read from the supported USB receiver.
    private static let descriptorHex = "05010905a1010501093aa102750895020501093f093b81017501150025013500450195040509190c290f810275011500250135004501950405090909090a090709088102750115002501350045019503050909050906090b810275019501810175011500250135004501950405091901290481027508150026ff00350046ff0095020501093209358102751016008026ff7f36008046ff7f05010901a10095020501093009318102c005010901a10095020501093309348102c07508950681010600ff150026ff00853109017508954d9102c0c0"

    private final class Session {
        let manager: IOHIDManager
        let device: IOHIDDevice
        let queue = DispatchQueue(label: "local.couchpilot.vader.hid")
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 20)
        let report: (VaderInputReport) -> Void
        let removed: () -> Void

        init(manager: IOHIDManager, device: IOHIDDevice,
             report: @escaping (VaderInputReport) -> Void, removed: @escaping () -> Void) {
            self.manager = manager
            self.device = device
            self.report = report
            self.removed = removed
        }

        func stop() {
            // Report callbacks only enqueue work on main, so waiting here cannot
            // block a callback that needs the main thread to return.
            queue.sync {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                IOHIDDeviceCancel(device)
            }
        }

        deinit { buffer.deallocate() }
    }

    private var session: Session?
    private var generation: UInt64 = 0
    var onReport: ((VaderInputReport) -> Void)?
    var onLoss: (() -> Void)?

    func open() throws {
        guard session == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x045e, kIOHIDProductIDKey: 0x028e,
            kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 5
        ] as CFDictionary)
        let candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter { device in
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            return product == "Flydigi VADER4" && transport == "USB"
                && descriptor?.map { String(format: "%02x", $0) }.joined() == Self.descriptorHex
        }
        guard candidates.count == 1, let device = candidates.first else { throw OpenError.noExactMatch }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else { throw OpenError.ownership(result) }
        generation &+= 1
        let id = generation
        let session = Session(manager: manager, device: device, report: { [weak self] report in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.session != nil else { return }
                self.onReport?(report)
            }
        }, removed: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.session != nil else { return }
                self.close()
                self.onLoss?()
            }
        })
        self.session = session
        let context = Unmanaged.passUnretained(session).toOpaque()
        IOHIDDeviceSetDispatchQueue(device, session.queue)
        IOHIDDeviceRegisterInputReportCallback(device, session.buffer, 20, { context, status, _, _, id, bytes, length in
            guard let context, status == kIOReturnSuccess, id == 0,
                  let report = VaderInputReport(UnsafeBufferPointer(start: bytes, count: length)) else { return }
            Unmanaged<Session>.fromOpaque(context).takeUnretainedValue().report(report)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<Session>.fromOpaque(context).takeUnretainedValue().removed()
        }, context)
        // Keep the device, callback context and buffer alive until IOKit drains callbacks.
        IOHIDDeviceSetCancelHandler(device) { withExtendedLifetime(session) {} }
        IOHIDDeviceActivate(device)
    }

    func close() {
        guard let session else { return }
        self.session = nil
        generation &+= 1
        session.stop()
    }

    deinit { session?.stop() }
}
