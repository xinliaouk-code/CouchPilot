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
        let size = min(size, frame.width, frame.height)
        panel.alphaValue = opacity
        panel.setFrame(CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2,
                              width: size, height: size), display: true)
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
    @Published var origin = ""
    @Published var device = ""
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

struct RadialView: View {
    @ObservedObject var state: RadialPresentation
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.05).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: size * 0.05).strokeBorder(.secondary.opacity(0.28))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text("CouchPilot").font(.system(size: size * 0.042, weight: .bold))
                        Text(state.device).foregroundStyle(.secondary)
                    }
                    Text("\(state.mouseMode ? "鼠标模式" : "手柄模式")  ·  \(state.origin)").foregroundStyle(.secondary)
                }
                .font(.system(size: size * 0.026))
                .padding(size * 0.045)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let choices = state.choices {
                    VStack(spacing: size * 0.04) {
                        Text(state.listTitle).font(.system(size: size * 0.065, weight: .bold))
                        if choices.isEmpty {
                            Text("没有可用应用").foregroundStyle(.secondary)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal) {
                                    HStack(spacing: size * 0.035) {
                                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, app in
                                            Button(action: app.action) {
                                                VStack {
                                                    if let icon = app.icon {
                                                        Image(nsImage: icon).resizable().scaledToFit()
                                                            .frame(width: size * 0.14, height: size * 0.14)
                                                    } else { Image(systemName: "app.dashed").font(.largeTitle) }
                                                    Text(app.name).lineLimit(2)
                                                }.frame(width: size * 0.24, height: size * 0.28)
                                                    .background(state.listIndex == index ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1),
                                                                in: RoundedRectangle(cornerRadius: 14))
                                            }.buttonStyle(.plain).id(index)
                                        }
                                    }.padding(.horizontal)
                                }
                                .onChange(of: state.listIndex) { _, index in
                                    if let index { proxy.scrollTo(index, anchor: .center) }
                                }
                            }
                        }
                    }
                } else {
                    Circle().strokeBorder(.secondary.opacity(0.25), lineWidth: 1).frame(width: size * 0.61)
                    VStack(spacing: 6) {
                        Text(state.selected?.label ?? "选择方向").font(.system(size: size * 0.033, weight: .semibold))
                        Text("松开触发键后保持").font(.system(size: size * 0.024)).foregroundStyle(.secondary)
                    }
                    .frame(width: size * 0.24, height: size * 0.24)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    ForEach(RadialAction.allCases) { action in
                        let angle = Double(action.rawValue) * .pi / 4
                        Button { state.choose?(action) } label: {
                            VStack(spacing: size * 0.01) {
                                Image(systemName: action.icon).font(.system(size: size * 0.05, weight: .medium))
                                Text(action.label).font(.system(size: size * 0.032, weight: .semibold))
                            }
                            .frame(width: size * 0.185, height: size * 0.125)
                            .background(state.selected == action ? Color.accentColor : Color.secondary.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: size * 0.028))
                            .foregroundStyle(state.selected == action ? Color.white : Color.primary)
                            .scaleEffect(state.selected == action ? 1.12 : 1)
                        }.buttonStyle(.plain)
                            .position(x: size / 2 + sin(angle) * size * 0.31,
                                      y: size / 2 - cos(angle) * size * 0.31)
                    }
                }
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Button("B 关闭") { state.close?() }
                        Button("LB 上一级") { state.back?() }.disabled(state.choices == nil)
                        Button("A 确认") { state.confirm?() }
                            .disabled(state.choices == nil ? state.selected == nil : state.listIndex == nil)
                    }.font(.system(size: size * 0.027, weight: .medium)).controlSize(.large)
                }.padding(.bottom, size * 0.04)
            }.frame(width: size, height: size)
        }
    }
}
