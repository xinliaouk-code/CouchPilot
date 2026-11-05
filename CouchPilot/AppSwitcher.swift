import AppKit

struct AppRecency {
    private(set) var order: [pid_t] = []
    mutating func activated(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }
    mutating func terminated(_ pid: pid_t) { order.removeAll { $0 == pid } }
    var current: pid_t? { order.first }
    var previous: pid_t? { order.dropFirst().first }
}

@MainActor
final class AppHistoryManager {
    private var recency = AppRecency()
    private var tokens: [NSObjectProtocol] = []
    private let workspace = NSWorkspace.shared
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init() {
        let center = workspace.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.record(app) }
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.recency.terminated(app.processIdentifier)
                }
            }
        })
        if let app = workspace.frontmostApplication { record(app) }
    }

    deinit { for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) } }

    private func record(_ app: NSRunningApplication) {
        if eligible(app) { recency.activated(app.processIdentifier) }
    }

    private func eligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != selfPID && !app.isTerminated
    }

    var currentActiveApp: NSRunningApplication? { recency.current.flatMap(NSRunningApplication.init(processIdentifier:)) }
    var previousApp: NSRunningApplication? { recency.previous.flatMap(NSRunningApplication.init(processIdentifier:)) }
    var recentNames: [String] {
        recency.order.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }
    var running: [NSRunningApplication] {
        let ranks = Dictionary(uniqueKeysWithValues: recency.order.enumerated().map { ($0.element, $0.offset) })
        return workspace.runningApplications.filter(eligible).sorted {
            let lhs = ranks[$0.processIdentifier] ?? Int.max, rhs = ranks[$1.processIdentifier] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            let nameOrder = ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "")
            return nameOrder == .orderedSame ? $0.processIdentifier < $1.processIdentifier : nameOrder == .orderedAscending
        }
    }
}

struct FavoriteApp: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let path: String
    let name: String

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, identifier != Bundle.main.bundleIdentifier else { return nil }
        bundleID = identifier
        path = url.path
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    @MainActor var url: URL? {
        let original = URL(fileURLWithPath: path)
        if Bundle(url: original)?.bundleIdentifier == bundleID { return original }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

@MainActor
final class AppSwitcher {
    private let workspace = NSWorkspace.shared
    var onError: ((String) -> Void)?
    var onSuccess: ((String) -> Void)?

    func activate(_ app: NSRunningApplication?, name: String) {
        guard let app, !app.isTerminated else { onError?("\(name) 已退出或暂无记录。"); return }
        guard app.isActive || app.activate() else { onError?("无法激活 \(name)。"); return }
        onSuccess?("已请求激活 \(name)")
    }

    func open(_ favorite: FavoriteApp) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: favorite.bundleID).first(where: { !$0.isTerminated }) {
            activate(running, name: favorite.name)
        } else { open(url: favorite.url, name: favorite.name) }
    }

    func finder() {
        let identifier = "com.apple.finder"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            activate(app, name: "Finder")
        } else {
            open(url: workspace.urlForApplication(withBundleIdentifier: identifier), name: "Finder")
        }
    }

    func browser() {
        guard let probe = URL(string: "https://example.invalid") else { return }
        let url = workspace.urlForApplication(toOpen: probe)
        open(url: url, name: "默认浏览器")
    }

    private func open(url: URL?, name: String) {
        guard let url else { onError?("找不到 \(name)。"); return }
        if let id = Bundle(url: url)?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
            activate(app, name: name)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if let error { self?.onError?("\(name)：\(error.localizedDescription)") }
                else if app == nil { self?.onError?("未能启动 \(name)。") }
                else { self?.onSuccess?("已请求打开 \(name)") }
            }
        }
    }
}
