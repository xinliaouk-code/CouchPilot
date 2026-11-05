import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@main
@MainActor
final class CouchPilotApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = CouchPilotApp()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private let model = ControllerModel()
    private let triggers = TriggerManager()
    private let history = AppHistoryManager()
    private let switcher = AppSwitcher()
    private let settings = SettingsStore()
    private var exposed: Set<String> = []
    private var sleepTokens: [NSObjectProtocol] = []
    private var screenToken: NSObjectProtocol?
    private var backgroundHomeSeen = false
    private var pausedForSession = false
    private let mouse = MouseEmulationEngine()
    private let overlay = RadialOverlayWindow()
    private var status: NSStatusItem?
    private var window: NSWindow?
    private var visible = false
    private var held: Set<String> = []
    private var left = CGPoint.zero
    private var selection = RadialSelection()
    private let radial = RadialPresentation()
    private var menuOriginApp: NSRunningApplication?
    private var listArmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "CouchPilot")
        status?.button?.target = self
        status?.button?.action = #selector(statusClicked)
        status?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        triggers.fire = { [weak self] in self?.toggle($0) }
        switcher.onError = { [weak self] message in self?.reportError("Application", message) }
        switcher.onSuccess = { [weak self] message in self?.model.log("application", "switch", message) }
        settings.learningChanged = { [weak self] in
            self?.mouse.suspend()
            self?.triggers.reset()
        }
        settings.changed = { [weak self] old in self?.applySettings(previous: old) }
        settings.recheck = { [weak self] in self?.refreshPermission() }
        settings.setMode = { [weak self] in self?.setMode($0) }
        settings.refreshRecent = { [weak self] in self?.refreshRecent() }
        radial.confirm = { [weak self] in self?.confirmSelection() }
        radial.choose = { [weak self] in self?.choose($0) }
        radial.close = { [weak self] in self?.close() }
        radial.back = { [weak self] in self?.back() }
        model.onInput = { [weak self] held, left, right, tick in self?.route(held, left, right, tick) }
        mouse.onError = { [weak self] message in
            self?.settings.trusted = AXIsProcessTrusted()
            self?.reportError("Mouse", message)
        }
        model.onFocus = { [weak self] active in
            guard let self, !self.model.background else { return }
            self.mouse.suspend()
            self.triggers.reset()
            if active { self.model.publishDevice() }
        }
        model.onDevice = { [weak self] available, held, left, _ in
            guard let self else { return }
            self.mouse.suspend()
            self.exposed = available
            self.held = held
            self.left = left
            self.backgroundHomeSeen = false
            self.triggers.reset()
            self.configureCombination()
            self.triggers.update(pressed: held, tick: DispatchTime.now().uptimeNanoseconds)
            if available.isEmpty, self.visible { self.close() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            sleepTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pausedForSession = name == NSWorkspace.willSleepNotification || name == NSWorkspace.sessionDidResignActiveNotification
                    self.mouse.suspend()
                    self.model.cancelHomeDiagnostic()
                    self.triggers.reset()
                    if self.pausedForSession { self.close(restoreFocus: false) }
                    else { self.model.publishDevice() }
                }
            })
        }
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutOverlay() }
        }
        applySettings(previous: nil)
        setMode(settings.value.startInMouse)
        model.publishDevice()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = status?.button {
            let menu = NSMenu()
            let open = NSMenuItem(title: "设置与诊断…", action: #selector(showDiagnostics), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let quit = NSMenuItem(title: "退出 CouchPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else { toggle("Menu bar") }
    }

    private func applySettings(previous: PilotConfiguration?) {
        let value = settings.value
        if previous?.background != value.background {
            mouse.suspend()
            triggers.reset()
            model.background = value.background
            model.publishDevice()
        }
        if previous?.requestHomeGestureDisabled != value.requestHomeGestureDisabled {
            model.gestureDisabled = value.requestHomeGestureDisabled
        }
        if previous?.homeOpensRadial != value.homeOpensRadial ||
            previous?.homeMS != value.homeMS || previous?.comboMS != value.comboMS ||
            previous?.combo != value.combo || previous?.comboEnabled != value.comboEnabled {
            mouse.suspend()
            triggers.homeEnabled = value.homeOpensRadial
            triggers.homeMS = value.homeMS
            triggers.comboMS = value.comboMS
            configureCombination()
            triggers.update(pressed: held, tick: DispatchTime.now().uptimeNanoseconds)
        }
        if previous?.hotKey != value.hotKey || previous?.hotModifiers != value.hotModifiers {
            let result = triggers.register(key: value.hotKey, modifiers: value.hotModifiers)
            settings.keyboard = result == noErr ? "Available · 已注册，后台实测待确认" : "Conflict · OSStatus \(result)"
            model.log("setting", "Keyboard shortcut", settings.keyboard)
        }
        mouse.tuning = value.mouse
        mouse.display = value.display
        selection.threshold = value.selectionThreshold
        if previous?.display != value.display || previous?.scale != value.scale || previous?.opacity != value.opacity {
            layoutOverlay()
        }
    }

    private func configureCombination() {
        let value = settings.value
        let chord = Set(value.combo)
        let supported = chord.count == 3 && chord.isSubset(of: exposed)
        triggers.combination = value.comboEnabled && supported ? chord : []
        settings.combo = !value.comboEnabled ? "Not Verified · 已停用"
            : (supported ? "Available · 键已暴露" : "Not Verified · 缺少 \(chord.subtracting(exposed).sorted().joined(separator: ", "))")
        if exposed.contains("Home"), !value.homeOpensRadial {
            settings.home = "已暴露 · 仅诊断"
        } else if exposed.contains("Home") {
            settings.home = backgroundHomeSeen ? "已收到后台长按 · 本次连接" : "Not Verified · 已暴露，后台待验证"
        } else { settings.home = "Not Verified · 未暴露或未连接" }
    }

    private func refreshPermission() {
        settings.trusted = mouse.recheck()
        if !settings.trusted { mouse.suspend() }
    }

    private func setMode(_ mouseMode: Bool) {
        mouse.suspend()
        radial.mouseMode = mouseMode
        settings.mouseMode = mouseMode
        close()
        if mouseMode {
            refreshPermission()
            if !settings.trusted { reportError("Mouse", "需要辅助功能权限。请在设置的鼠标页授权并重新检查。") }
        }
        model.log("mode", "control", mouseMode ? "mouse" : "native")
    }

    private func refreshRecent() {
        settings.recent = history.recentNames
        settings.previous = history.previousApp?.localizedName ?? "—"
    }

    private func reportError(_ source: String, _ message: String) {
        settings.lastError = message
        status?.button?.toolTip = message
        model.log("error", source, message)
    }

    private func layoutOverlay() {
        guard visible else { return }
        overlay.layout(screen: DisplayManager.screen(preferred: settings.value.display),
                       size: 520 * settings.value.scale, opacity: settings.value.opacity)
    }

    private func route(_ pressed: Set<String>, _ left: CGPoint, _ right: CGPoint, _ tick: UInt64) {
        let edges = pressed.subtracting(held)
        held = pressed
        self.left = left
        guard !pausedForSession, model.background || NSApp.isActive else { return }
        if settings.learning {
            mouse.suspend()
            triggers.reset()
            if let key = edges.intersection(exposed).subtracting(["Home"]).subtracting(settings.learned).sorted().first {
                settings.learned.append(key)
                if settings.learned.count == 3 {
                    settings.learning = false
                    settings.value.combo = settings.learned
                }
            }
            return
        }
        let wasVisible = visible
        triggers.update(pressed: pressed, tick: tick)
        guard wasVisible == visible else { return }
        guard visible else {
            if radial.mouseMode, model.background || NSApp.isActive { mouse.consume(pressed.subtracting(triggers.combination.intersection(["A", "B", "X", "Y"])), left: left, right: right) }
            return
        }
        if edges.contains("B") { close(); return }
        if radial.choices != nil {
            if edges.contains("LB") { back(); return }
            let direction = listDirection(left, edges: edges)
            if let direction, let choices = radial.choices, !choices.isEmpty {
                let start = radial.listIndex ?? (direction > 0 ? -1 : choices.count)
                radial.listIndex = max(0, min(choices.count - 1, start + direction))
            }
            if edges.contains("A") { confirmSelection() }
        } else {
            selection.update(left)
            if radial.selected != selection.selected { radial.selected = selection.selected }
            if edges.contains("A") { confirmSelection() }
        }
    }

    private func confirmSelection() {
        guard visible else { return }
        if let choices = radial.choices {
            if let index = radial.listIndex, choices.indices.contains(index) { choices[index].action() }
        } else if let action = radial.selected { choose(action) }
    }

    private func listDirection(_ point: CGPoint, edges: Set<String>) -> Int? {
        if hypot(point.x, point.y) < 0.20 { listArmed = true }
        if edges.contains("Left") || edges.contains("Up") { return -1 }
        if edges.contains("Right") || edges.contains("Down") { return 1 }
        guard listArmed, abs(point.x) >= 0.50 else { return nil }
        listArmed = false
        return point.x > 0 ? 1 : -1
    }

    private func back() {
        radial.choices = nil
        radial.listIndex = nil
        selection = RadialSelection(threshold: settings.value.selectionThreshold)
        selection.update(left)
        radial.selected = selection.selected
    }

    private func toggle(_ source: String) {
        guard !pausedForSession else { return }
        settings.lastTrigger = source
        if source == "Home", !NSApp.isActive, model.background {
            backgroundHomeSeen = true
            settings.home = "已收到后台长按 · 本次连接"
        }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        model.log("trigger", source, "\(visible ? "close" : "open"); frontmost=\(app)")
        if visible { close(); return }
        mouse.suspend()
        menuOriginApp = NSWorkspace.shared.frontmostApplication
        visible = true
        back()
        radial.origin = menuOriginApp?.localizedName ?? "桌面"
        radial.device = model.device
        overlay.show(RadialView(state: radial), screen: DisplayManager.screen(preferred: settings.value.display),
                     size: 520 * settings.value.scale, opacity: settings.value.opacity)
    }

    private func close(restoreFocus: Bool = true) {
        visible = false
        overlay.hide()
        if restoreFocus, let origin = menuOriginApp, !origin.isTerminated, !origin.isActive,
           origin.processIdentifier != ProcessInfo.processInfo.processIdentifier, !origin.activate() {
            reportError("Overlay", "无法返回呼出轮盘前的应用。")
        }
        menuOriginApp = nil
    }

    private func choose(_ action: RadialAction) {
        guard visible else { return }
        switch action {
        case .settings: close(restoreFocus: false); showDiagnostics()
        case .mouse, .native:
            setMode(action == .mouse)
        case .running:
            showList(action.label, choices: history.running.map { app in
                let name = app.localizedName ?? "应用"
                return AppChoice(id: String(app.processIdentifier), name: name, icon: app.icon) { [weak self] in
                    self?.performSwitch { self?.switcher.activate(app, name: name) }
                }
            })
        case .favorites:
            showList(action.label, choices: settings.value.favorites.map { favorite in
                let icon = favorite.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                return AppChoice(id: favorite.id, name: favorite.name, icon: icon) { [weak self] in
                    self?.performSwitch { self?.switcher.open(favorite) }
                }
            })
        case .previous:
            let previous = history.previousApp
            performSwitch { switcher.activate(previous, name: previous?.localizedName ?? "上一应用") }
        case .finder: performSwitch { switcher.finder() }
        case .browser: performSwitch { switcher.browser() }
        }
    }

    private func showList(_ title: String, choices: [AppChoice]) {
        radial.listTitle = title
        radial.listIndex = nil
        listArmed = hypot(left.x, left.y) < 0.20
        radial.choices = choices
    }

    private func performSwitch(_ action: () -> Void) {
        guard visible else { return }
        close(restoreFocus: false)
        action()
    }

    @objc private func showDiagnostics() {
        if visible { close(restoreFocus: false) }
        mouse.suspend()
        refreshPermission()
        refreshRecent()
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 990, height: 740),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "CouchPilot 设置与诊断"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PilotSettingsView(store: settings, model: model))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouse.suspend()
        triggers.reset()
        triggers.unregister()
        for token in sleepTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
    }
}
