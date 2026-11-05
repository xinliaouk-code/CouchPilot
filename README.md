# CouchPilot P0

macOS 原生 GameController 手柄诊断工具。最低 macOS 13；无第三方依赖。当前仅观察第一个 GameController 设备，输入视图使用 Extended Gamepad profile。设备未提供该 profile 或 `buttonHome` 时，界面显示不可用，而不生成虚构输入。

## 构建和运行

用 Xcode 打开 `CouchPilot.xcodeproj`，选择 CouchPilot scheme 并运行；或在终端构建：

```sh
xcodebuild -project CouchPilot.xcodeproj -scheme CouchPilot -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

输出为 `build/Build/Products/Release/CouchPilot.app`。这是本机未签名的开发构建，不是公证或发布版本。运行由用户手动启动。GameController 读取本身不需要辅助功能、输入监控或屏幕录制授权；此工具不会请求或绕过这些权限。系统设置中的手柄选项及名称可能因 macOS 版本而异。

## 测试步骤

1. 连接 Vader 4 Pro 的 2.4GHz 接收器并打开手柄。确认界面设备名称及 Extended Gamepad、Home 暴露状态；如果系统识别名称不同，请记录实际名称及连接模式。
2. 系统设置中找到游戏手柄的 Controller Shortcuts，分别设为 ON 和 OFF。每次设置后在 App 前台测试 A/B、双摇杆、Home 短按和至少 600ms 长按，并观察是否出现 Games/Spotlight。
3. 启用「后台监听」，手动切到 Safari，重复 ON/OFF 两组。观察系统界面后返回 CouchPilot，按事件的 `appState`、时间及 Home press/release/threshold 判断实际收到的事件。后台监听不独占输入，也不保证系统会转发 Home。若没有事件，记录「否」或「不确定」及当时画面，不推断其唯一原因。
4. 在测试矩阵逐格选择「是 / 否 / 不确定」，未执行保持「未测」。最后一列的「是」表示 Games/Spotlight 确实打开，不能直接当成通过。结果保存在本机 UserDefaults；手动修改会写入当前事件流。
5. 分别导出 JSON 和 CSV。JSON 包含本次事件和当前全部手动结果；CSV 是本次会话事件，包含本次手动结果变更。重新启动后事件不会自动恢复，测试完请在退出前导出。输入事件可能很多，长时间运行会消耗内存。
6. 拔下接收器、重新连接，检查连接状态和输入是否恢复；本工具只选择系统列表中的第一个设备，多设备时请先断开其他手柄。

Home 显示 `isBoundToSystemGesture` 及 `preferredSystemGestureState`。开关只请求 enabled/disabled；Apple SDK 说明系统不保证遵从。切换系统手势偏好也是实验变量，应在四组基线中保持关闭（enabled），再单独记录开启请求后的观察。长按时会产生 600ms threshold 事件，释放时记录由单调时钟计算的时长；断连或未收到 release 时不会伪造时长。时间戳为 App 处理事件时的墙上时间，uptime 为回调采样时间，非硬件时间戳。系统可能延迟、吞掉或改变事件顺序，不能据此推断物理按键的精确时刻。

## 验证与后续

见 [测试结果](TEST_RESULTS.md) 和 [无界面设备探测日志](diagnostics/controller-probe.txt)。四组真实设备及 UI 检查必须由用户在可见桌面完成，目前未验收。P1 的八向轮盘应在 P0 证明 Home 在目标场景可用后，订阅独立的输入事件流；加入摇杆死区、方向滞回、取消和释放状态机，并先用可注入事件源测试，再用真实前后台输入验收。不要把模拟输入当作 Home 硬件证据；鼠标注入、应用切换及权限设计均另行确定。
