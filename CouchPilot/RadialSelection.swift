import Foundation

enum RadialAction: Int, CaseIterable, Identifiable {
    // North, clockwise. The center is presentation only.
    case running, inputMode, favorites, previous, pause, finder, browser, settings

    static let grid: [[Self?]] = [
        [.settings, .running, .inputMode],
        [.browser, nil, .favorites],
        [.finder, .pause, .previous]
    ]

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .running: return "运行中应用"
        case .inputMode: return "输入模式"
        case .favorites: return "收藏应用"
        case .previous: return "上一应用"
        case .pause: return "暂停 / 恢复"
        case .finder: return "Finder"
        case .browser: return "默认浏览器"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .running: return "macwindow.on.rectangle"
        case .inputMode: return "gamecontroller"
        case .favorites: return "star"
        case .previous: return "arrow.uturn.backward"
        case .pause: return "pause.circle"
        case .finder: return "folder"
        case .browser: return "globe"
        case .settings: return "gearshape"
        }
    }

    func detail(desktopMode: Bool, trusted: Bool) -> String {
        switch self {
        case .running: return "切换到其他正在运行的应用"
        case .inputMode:
            if desktopMode { return "切换到手柄模式" }
            return trusted ? "切换到桌面模式" : "桌面模式需要辅助功能授权"
        case .favorites: return "打开常用的应用"
        case .previous: return "返回上一个应用"
        case .pause: return "Smart Pause 未启用"
        case .finder: return "打开 Finder"
        case .browser: return "打开系统默认浏览器"
        case .settings: return "调整 CouchPilot 偏好"
        }
    }
}

struct RadialSelection {
    var threshold = 0.50
    private(set) var selected: RadialAction?
    private(set) var centered = false

    mutating func update(_ point: CGPoint) {
        let magnitude = hypot(point.x, point.y)
        if magnitude <= 0.20 { centered = true }
        guard centered, magnitude >= threshold else { return }
        let angle = atan2(point.x, point.y)
        if let selected {
            let delta = angle - Double(selected.rawValue) * .pi / 4
            if abs(atan2(sin(delta), cos(delta))) < .pi / 8 + .pi / 30 { return }
        }
        let index = Int((angle / (.pi / 4)).rounded())
        selected = RadialAction(rawValue: (index + 8) % 8)
    }
}
