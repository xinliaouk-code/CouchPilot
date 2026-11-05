import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ControllerModel
    @Binding var background: Bool
    @Binding var gestureDisabled: Bool
    @State private var homeOnly = false
    private let checks = ["A/B 正常", "摇杆正常", "Home Press", "Home Release", "Home ≥600ms", "Games/Spotlight 同时打开"]
    private let scenarios = ["Shortcuts ON · App 前台", "Shortcuts OFF · App 前台", "Shortcuts ON · Safari 前台", "Shortcuts OFF · Safari 前台"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CouchPilot · Controller Diagnostics").font(.largeTitle.bold())
                GroupBox("设备") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("状态：\(model.device)"); Text("Profile：\(model.profile)")
                        Text(model.homeInfo).textSelection(.enabled)
                        Toggle("后台监听（不独占输入；前台应用仍可接收）", isOn: $background)
                        Toggle("请求禁用 Home 系统手势（实验，系统可能不遵从）", isOn: $gestureDisabled).disabled(model.device == "未连接")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top) {
                    stick("左摇杆", model.left); stick("右摇杆", model.right)
                    GroupBox("按键 / 扳机") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                            ForEach(["A","B","X","Y","LB","RB","LT","RT","Up","Down","Left","Right","Menu","Options","L3","R3","Home"], id: \.self) { name in
                                VStack { Text(name).bold(); Text(String(format: "%.2f", model.buttons[name] ?? 0)).monospacedDigit() }
                                    .frame(maxWidth: .infinity).padding(5).background((model.buttons[name] ?? 0) > 0.1 ? Color.green.opacity(0.35) : Color.gray.opacity(0.12)).cornerRadius(6)
                            }
                        }.padding(4)
                    }
                }
                GroupBox("手动实机结果（每格点击选择；自动保存）") {
                    VStack(alignment: .leading) {
                        Text("先在系统设置切换 Controller Shortcuts；Safari 组启用后台监听并手动切换。每格记录实际观察，未测保持「未测」。")
                            .font(.caption).foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                            GridRow { Text("场景").bold(); ForEach(checks, id: \.self) { Text($0).font(.caption.bold()).frame(width: 105) } }
                            ForEach(scenarios, id: \.self) { scenario in
                                GridRow {
                                    Text(scenario).frame(width: 180, alignment: .leading)
                                    ForEach(checks, id: \.self) { check in
                                        let key = "\(scenario) / \(check)"
                                        Picker("", selection: Binding(get: { model.results[key] ?? "未测" }, set: { model.setResult(key, $0) })) {
                                            ForEach(["未测", "是", "否", "不确定"], id: \.self) { Text($0) }
                                        }.labelsHidden().frame(width: 105)
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Button("导出 JSON") { model.export(csv: false) }; Button("导出 CSV") { model.export(csv: true) }; Text(model.note).foregroundStyle(.secondary); Spacer(); Text("\(model.events.count) 条事件") }
                GroupBox("事件（最新 100 条；导出包含完整本次会话）") {
                    VStack(alignment: .leading) {
                        Toggle("仅显示 Home 和菜单触发", isOn: $homeOnly)
                        ForEach(Array((homeOnly ? model.events.filter { $0.input == "Home" || $0.type == "trigger" }
                                                  : model.events).suffix(100).reversed())) { event in
                            Text("\(event.timestamp) · \(event.appState) · \(event.input) · \(event.type) · \(event.value)\(event.durationMilliseconds.map { String(format: " · %.1f ms", $0) } ?? "")")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
    }
    private func stick(_ name: String, _ point: CGPoint) -> some View {
        GroupBox(name) {
            VStack {
                ZStack {
                    Circle().stroke(.secondary, lineWidth: 1).frame(width: 105, height: 105)
                    Circle().fill(.blue).frame(width: 12, height: 12).offset(x: max(-1, min(1, point.x)) * 46, y: -max(-1, min(1, point.y)) * 46)
                }
                Text(String(format: "X %+.2f  Y %+.2f", point.x, point.y)).monospacedDigit()
            }.padding(4)
        }
    }
}
