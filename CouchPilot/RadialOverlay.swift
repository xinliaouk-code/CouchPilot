import AppKit
import SwiftUI

private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class RadialOverlayWindow {
    private var panel: NSPanel?

    func show<V: View>(_ view: V, screen: NSScreen? = nil, size: CGFloat = 480, opacity: Double = 0.97) {
        let first = panel == nil
        let window = panel ?? makePanel()
        if first { window.contentView = OverlayHostingView(rootView: view) }
        layout(screen: screen, size: size, opacity: opacity)
        window.orderFrontRegardless()
    }

    func layout(screen: NSScreen?, size: CGFloat, opacity: Double) {
        guard let panel, let screen = screen ?? DisplayManager.screen() else { return }
        let frame = screen.visibleFrame
        let size = RadialDesign.windowSize(preferredPanelWidth: size, available: frame.size)
        panel.alphaValue = opacity
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = window
        return window
    }
}

@MainActor
enum DisplayManager {
    static func id(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(preferred: UInt32 = 0) -> NSScreen? {
        NSScreen.screens.first { id($0) == preferred }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }
}

struct AppChoice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let action: () -> Void
}

@MainActor
final class RadialPresentation: ObservableObject {
    @Published var foregroundName = ""
    @Published var foregroundIcon: NSImage?
    @Published var foregroundStatus = ""
    @Published var foregroundRunning = false
    @Published var triggerHint = ""
    @Published var desktopTrusted = false
    @Published var device = ""
    @Published var deviceConnected = false
    @Published var selected: RadialAction?
    @Published var mouseMode = false
    @Published var choices: [AppChoice]?
    @Published var listTitle = ""
    @Published var listIndex: Int?
    var confirm: (() -> Void)?
    var choose: ((RadialAction) -> Void)?
    var close: (() -> Void)?
    var back: (() -> Void)?
}


enum RadialDesign {
    static let windowWidthRatio: CGFloat = 1.28
    static let windowHeightRatio: CGFloat = 1.20
    static let glassHeightRatio: CGFloat = 0.94
    static let cornerRatio: CGFloat = 0.19
    static let centerCornerRatio: CGFloat = 0.078
    static let edge = Color.white.opacity(0.26)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.68)
    static let highlight = Color.white.opacity(0.08)
    static let center = Color.white.opacity(0.14)
    static let glassTint = Color(white: 0.10).opacity(0.40)
    static let transition = Animation.easeOut(duration: 0.15)

    static func windowSize(preferredPanelWidth: CGFloat, available: CGSize) -> CGSize {
        let width = min(preferredPanelWidth, available.width / windowWidthRatio, available.height / windowHeightRatio)
        return CGSize(width: width * windowWidthRatio, height: width * windowHeightRatio)
    }
}

private struct DesktopGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct RadialView: View {
    @ObservedObject var state: RadialPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width / RadialDesign.windowWidthRatio,
                            geometry.size.height / RadialDesign.windowHeightRatio)
            VStack(spacing: 0) {
                statusBar(width).frame(height: width * 0.13)
                glass(width).frame(width: width, height: width * RadialDesign.glassHeightRatio)
                controls(width).frame(height: width * 0.13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(RadialDesign.text)
            .environment(\.colorScheme, .dark)
        }
    }

    private func statusBar(_ width: CGFloat) -> some View {
        HStack(spacing: width * 0.018) {
            Label("CouchPilot", systemImage: "gamecontroller.fill")
                .fontWeight(.semibold).fixedSize()
            HStack(spacing: width * 0.009) {
                Circle().fill(state.deviceConnected ? Color.green : RadialDesign.secondary)
                    .frame(width: width * 0.010)
                Text(state.device).truncationMode(.tail)
            }.foregroundStyle(RadialDesign.secondary)
            Spacer(minLength: width * 0.018)
            if !state.foregroundName.isEmpty {
                HStack(spacing: width * 0.013) {
                    if let icon = state.foregroundIcon {
                        Image(nsImage: icon).resizable().scaledToFit()
                            .frame(width: width * 0.032, height: width * 0.032)
                    }
                    Text(state.foregroundName).truncationMode(.tail)
                    Text(state.foregroundStatus)
                        .foregroundStyle(state.foregroundRunning ? Color.green : RadialDesign.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, width * 0.019)
                .padding(.vertical, width * 0.008)
                .background(.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .layoutPriority(1)
            }
            Spacer(minLength: width * 0.018)
            Text("暂停策略：未启用").foregroundStyle(RadialDesign.secondary).fixedSize()
        }
        .font(.system(size: width * 0.028))
        .lineLimit(1)
        .padding(.horizontal, width * 0.025)
        .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
    }

    private func glass(_ width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * RadialDesign.cornerRatio, style: .continuous)
        return ZStack {
            DesktopGlass()
            RadialDesign.glassTint
            if let choices = state.choices {
                appList(choices, width: width)
            } else {
                grid(width)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(RadialDesign.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: width * 0.038, y: width * 0.015)
    }

    private func grid(_ width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(RadialAction.grid.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(RadialAction.grid[row].indices, id: \.self) { column in
                        Group {
                            if let action = RadialAction.grid[row][column] {
                                tile(action, width: width)
                            } else {
                                selection(width)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, width * 0.026)
        .padding(.vertical, width * 0.029)
        .animation(reduceMotion ? nil : RadialDesign.transition, value: state.selected)
    }

    private func tile(_ action: RadialAction, width: CGFloat) -> some View {
        let selected = state.selected == action
        return Button { state.choose?(action) } label: {
            VStack(spacing: width * 0.012) {
                HStack(spacing: width * 0.014) {
                    Image(systemName: action.icon)
                    if action == .inputMode { Image(systemName: "arrow.left.arrow.right") }
                }
                .font(.system(size: width * 0.066, weight: .light))
                .frame(height: width * 0.078)
                Text(action.label).font(.system(size: width * 0.033, weight: .medium))
                if action == .inputMode {
                    Text(state.mouseMode ? "当前：桌面模式" : "当前：手柄模式")
                        .font(.system(size: width * 0.022))
                        .foregroundStyle(RadialDesign.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: width * 0.285, height: width * 0.24)
            .background(selected ? RadialDesign.highlight : .clear,
                        in: RoundedRectangle(cornerRadius: width * 0.053, style: .continuous))
            .contentShape(Rectangle())
            .opacity(action == .pause ? 0.52 : (selected ? 1 : 0.87))
        }
        .buttonStyle(.plain)
        .disabled(action == .pause)
    }

    private func selection(_ width: CGFloat) -> some View {
        let action = state.selected
        let shape = RoundedRectangle(cornerRadius: width * RadialDesign.centerCornerRatio, style: .continuous)
        return VStack(spacing: width * 0.013) {
            Image(systemName: action?.icon ?? "gamecontroller")
                .font(.system(size: width * 0.087, weight: .light))
            Text(action?.label ?? "选择方向")
                .font(.system(size: width * 0.038, weight: .semibold))
            Text(action?.detail(desktopMode: state.mouseMode, trusted: state.desktopTrusted)
                 ?? (state.mouseMode ? "当前：桌面模式" : "当前：手柄模式"))
                .font(.system(size: width * 0.022))
                .foregroundStyle(RadialDesign.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, width * 0.012)
        .id(action)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadialDesign.center, in: shape)
        .overlay(shape.strokeBorder(RadialDesign.edge, lineWidth: 1))
        .allowsHitTesting(false)
    }

    private func appList(_ choices: [AppChoice], width: CGFloat) -> some View {
        VStack(spacing: width * 0.036) {
            Text(state.listTitle).font(.system(size: width * 0.052, weight: .semibold))
            if choices.isEmpty {
                Text("没有可用应用").foregroundStyle(RadialDesign.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: width * 0.028) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, app in
                                Button(action: app.action) {
                                    VStack(spacing: width * 0.018) {
                                        if let icon = app.icon {
                                            Image(nsImage: icon).resizable().scaledToFit()
                                                .frame(width: width * 0.12, height: width * 0.12)
                                        } else {
                                            Image(systemName: "app.dashed").font(.system(size: width * 0.09))
                                        }
                                        Text(app.name).font(.system(size: width * 0.025)).lineLimit(2)
                                    }
                                    .frame(width: width * 0.23, height: width * 0.26)
                                    .background(state.listIndex == index ? RadialDesign.center : .clear,
                                                in: RoundedRectangle(cornerRadius: width * 0.035))
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }.padding(.horizontal, width * 0.08)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: state.listIndex) { _, index in
                        if let index {
                            withAnimation(reduceMotion ? nil : RadialDesign.transition) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func controls(_ width: CGFloat) -> some View {
        HStack(spacing: width * 0.023) {
            hint("L", "选择")
            Button { state.confirm?() } label: { hint("A", "确认") }.buttonStyle(.plain)
            Button { state.close?() } label: { hint("B", "关闭") }.buttonStyle(.plain)
            if state.choices != nil {
                Button { state.back?() } label: { hint("LB", "返回") }.buttonStyle(.plain)
            } else {
                Text(state.triggerHint).truncationMode(.tail)
            }
        }
        .font(.system(size: width * 0.026, weight: .medium))
        .foregroundStyle(RadialDesign.text)
        .lineLimit(1)
        .padding(.horizontal, width * 0.025)
        .padding(.vertical, width * 0.012)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(RadialDesign.edge))
        .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key).padding(.horizontal, 5).padding(.vertical, 2)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(RadialDesign.text)
            Text(label)
        }.fixedSize()
    }
}
