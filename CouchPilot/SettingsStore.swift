import AppKit
import Carbon
import ServiceManagement
import SwiftUI

struct PilotConfiguration: Codable, Equatable {
    var startInMouse = false
    var homeMS = 600
    var comboEnabled = true
    var comboMS = 700
    var combo = ["LB", "RB", "Menu"]
    var hotKey = UInt32(kVK_Space)
    var hotModifiers = UInt32(controlKey | optionKey)
    var background = true
    var requestHomeGestureDisabled = false
    var scale = 1.0
    var opacity = 0.97
    var selectionThreshold = 0.50
    var display: UInt32 = 0
    var mouse = MouseTuning()
    var favorites: [FavoriteApp] = []
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var value: PilotConfiguration {
        didSet {
            guard value != oldValue else { return }
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "pilotSettings") }
            changed?(oldValue)
        }
    }
    @Published var mouseMode = false
    @Published var trusted = false
    @Published var keyboard = "Not Verified"
    @Published var combo = "Not Verified"
    @Published var home = "Not Verified"
    @Published var lastTrigger = "—"
    @Published var lastError = "—"
    @Published var recent: [String] = []
    @Published var previous = "—"
    @Published var learning = false { didSet { learningChanged?() } }
    @Published var learned: [String] = []
    @Published var loginStatus = ""
    var learningChanged: (() -> Void)?
    var changed: ((PilotConfiguration) -> Void)?
    var recheck: (() -> Void)?
    var setMode: ((Bool) -> Void)?
    var refreshRecent: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: "pilotSettings").flatMap { try? JSONDecoder().decode(PilotConfiguration.self, from: $0) }
            ?? PilotConfiguration()
    }

    func updateLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "已启用"
        case .requiresApproval: loginStatus = "等待系统设置批准"
        case .notFound: loginStatus = "找不到已安装 App"
        case .notRegistered: loginStatus = "未注册"
        @unknown default: loginStatus = "状态未知"
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = error.localizedDescription }
        updateLoginStatus()
    }
}

struct PilotSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: ControllerModel
    @State private var favoriteSelection: String?
    @State private var screens = NSScreen.screens

    private let hotKeys: [(String, Int)] = [
        ("Space", kVK_Space), ("F6", kVK_F6), ("F7", kVK_F7), ("F8", kVK_F8),
        ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12),
        ("C", kVK_ANSI_C), ("P", kVK_ANSI_P), ("R", kVK_ANSI_R), ("M", kVK_ANSI_M)
    ]

    var body: some View {
        TabView {
            Form {
                LabeledContent("菜单栏", value: "常驻 · 点击图标切换轮盘")
                Picker("当前模式", selection: Binding(get: { store.mouseMode }, set: { store.setMode?($0) })) {
                    Text("手柄").tag(false)
                    Text("鼠标").tag(true)
                }
                Picker("默认启动模式", selection: $store.value.startInMouse) {
                    Text("手柄").tag(false)
                    Text("鼠标").tag(true)
                }
                LabeledContent("登录时打开", value: store.loginStatus)
                HStack {
                    Button("启用") { store.setLogin(true) }
                    Button("停用") { store.setLogin(false) }
                    Button("刷新") { store.updateLoginStatus() }
                }
                Button("退出 CouchPilot") { NSApp.terminate(nil) }
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gear") }

            Form {
                Toggle("监听后台手柄事件", isOn: $store.value.background)
                Toggle("请求禁用 Home 系统手势", isOn: $store.value.requestHomeGestureDisabled)
                Stepper("Home 长按 · \(store.value.homeMS) ms", value: $store.value.homeMS, in: 200...2000, step: 50)
                LabeledContent("Home", value: store.home)
                LabeledContent("菜单栏入口", value: "Available")
                Picker("快捷键修饰键", selection: $store.value.hotModifiers) {
                    Text("Control + Option").tag(UInt32(controlKey | optionKey))
                    Text("Control + Shift").tag(UInt32(controlKey | shiftKey))
                    Text("Command + Option").tag(UInt32(cmdKey | optionKey))
                    Text("Control + Option + Shift").tag(UInt32(controlKey | optionKey | shiftKey))
                }
                Picker("快捷键", selection: $store.value.hotKey) {
                    ForEach(hotKeys, id: \.1) { key in Text(key.0).tag(UInt32(key.1)) }
                }
                LabeledContent("键盘注册", value: store.keyboard)
                Toggle("启用备用手柄组合键", isOn: $store.value.comboEnabled)
                Stepper("组合键长按 · \(store.value.comboMS) ms", value: $store.value.comboMS, in: 300...2500, step: 50)
                LabeledContent(store.value.combo.joined(separator: " + "), value: store.combo)
                HStack {
                    Button(store.learning ? "取消学习" : "学习三个手柄键") {
                        store.learned = []
                        store.learning.toggle()
                    }
                    Button("恢复默认") { store.value.combo = ["LB", "RB", "Menu"] }
                }
                if store.learning {
                    Text("依次按三个不同的手柄按钮 · \(store.learned.joined(separator: " + "))")
                }
                Text("组合键也可能被前台游戏收到。鼠标模式下，组合键中的鼠标操作键将保留给组合键。")
                    .foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("触发", systemImage: "button.programmable") }

            Form {
                Picker("轮盘缩放", selection: $store.value.scale) {
                    Text("100%").tag(1.0)
                    Text("125%").tag(1.25)
                    Text("150%").tag(1.5)
                }
                slider("面板不透明度", $store.value.opacity, 0.65...1)
                slider("选区幅度阈值", $store.value.selectionThreshold, 0.35...0.85)
                Picker("显示器", selection: $store.value.display) {
                    Text("鼠标所在显示器").tag(UInt32(0))
                    if store.value.display != 0 && !screens.contains(where: { DisplayManager.id($0) == store.value.display }) {
                        Text("显示器已断开（自动回退）").tag(store.value.display)
                    }
                    ForEach(screens, id: \.self) { screen in Text(screen.localizedName).tag(DisplayManager.id(screen)) }
                }
                Text("固定布局 · 北起顺时针")
                Text(RadialAction.allCases.map(\.label).joined(separator: " · ")).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("轮盘", systemImage: "circle.grid.cross") }

            Form {
                LabeledContent("辅助功能", value: store.trusted ? "已授权" : "未授权")
                HStack {
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("重新检查") { store.recheck?() }
                }
                slider("死区", $store.value.mouse.deadzone, 0.05...0.4)
                slider("灵敏度", $store.value.mouse.sensitivity, 0.3...2)
                slider("最大速度", $store.value.mouse.maximum, 200...3500)
                slider("加速度曲线", $store.value.mouse.acceleration, 0.7...3)
                slider("精细模式速度", $store.value.mouse.fine, 0.1...0.75)
                slider("滚动速度", $store.value.mouse.scroll, 100...1400)
                Toggle("限制光标在选定显示器", isOn: $store.value.mouse.restrict)
            }.formStyle(.grouped).tabItem { Label("鼠标", systemImage: "cursorarrow") }

            Form {
                Section("收藏应用") {
                    Picker("应用", selection: $favoriteSelection) {
                        Text("选择收藏").tag(String?.none)
                        ForEach(store.value.favorites) { item in
                            Label {
                                Text(item.name)
                            } icon: {
                                if let url = item.url {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                } else { Image(systemName: "app.dashed") }
                            }.tag(Optional(item.id))
                        }
                    }
                    HStack {
                        Button("添加…", action: addFavorite)
                        Button("上移") { moveFavorite(-1) }.disabled(favoriteSelection == nil)
                        Button("下移") { moveFavorite(1) }.disabled(favoriteSelection == nil)
                        Button("移除") {
                            store.value.favorites.removeAll { $0.id == favoriteSelection }
                            favoriteSelection = nil
                        }.disabled(favoriteSelection == nil)
                    }
                }
                LabeledContent("上一应用", value: store.previous)
                LabeledContent("最近应用", value: store.recent.joined(separator: " → "))
                Button("刷新") { store.refreshRecent?() }
            }.formStyle(.grouped).tabItem { Label("应用", systemImage: "square.stack") }

            VStack(alignment: .leading) {
                Text("触发 · \(store.lastTrigger)    辅助功能 · \(store.trusted ? "已授权" : "未授权")")
                Text("最近错误 · \(store.lastError)").textSelection(.enabled)
                ContentView(model: model, background: $store.value.background, gestureDisabled: $store.value.requestHomeGestureDisabled)
            }.padding(12).tabItem { Label("诊断", systemImage: "waveform.path") }
        }
        .onAppear { store.updateLoginStatus(); store.recheck?(); store.refreshRecent?() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range).frame(width: 240)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 64)
        }
    }

    private func addFavorite() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            guard let favorite = FavoriteApp(url: url) else { store.lastError = "无法收藏所选应用。"; return }
            if !store.value.favorites.contains(where: { $0.id == favorite.id }) { store.value.favorites.append(favorite) }
            favoriteSelection = favorite.id
        }
    }

    private func moveFavorite(_ delta: Int) {
        guard let index = store.value.favorites.firstIndex(where: { $0.id == favoriteSelection }),
              store.value.favorites.indices.contains(index + delta) else { return }
        store.value.favorites.swapAt(index, index + delta)
    }
}
