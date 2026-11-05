import Foundation

enum RadialAction: Int, CaseIterable, Identifiable {
    case running, mouse, native, favorites, previous, finder, browser, settings
    var id: Int { rawValue }
    var label: String {
        ["运行中应用", "鼠标模式", "手柄模式", "收藏应用", "上一应用", "Finder", "默认浏览器", "设置"][rawValue]
    }
    var icon: String {
        ["square.stack", "cursorarrow", "gamecontroller", "star", "arrow.uturn.backward", "folder", "globe", "gearshape"][rawValue]
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
