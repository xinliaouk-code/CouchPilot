# P0 测试记录

日期：2026-11-05。构建环境：Apple Silicon，macOS 27.0.1 (26A434)，Xcode 27.2，macOS SDK 27.2。

| 检查 | 结果 | 证据 |
|---|---|---|
| Release 编译 | PASS | xcodebuild BUILD SUCCEEDED；未签名 .app 已生成 |
| GameController 无界面探测 | 已运行 | [日志](diagnostics/controller-probe.txt)：0 台设备 |
| App 实际启动、界面和重连 | GUI_REQUIRED / 未测 | 需要用户授权可见 App 和手动操作；未改变桌面焦点 |
| 导出、Home 手势请求和后台事件 | GUI_REQUIRED / 未测 | 需要可见 App、连接目标手柄及用户操作 |

| Controller Shortcuts | 前台 | A/B | 摇杆 | Home 按下 | Home 释放 | ≥600ms | Games/Spotlight 打开 |
|---|---|---|---|---|---|---|---|
| ON | CouchPilot | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| OFF | CouchPilot | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| ON | Safari | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| OFF | Safari | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |

Home 可行性结论：**PARTIAL（尚未验证）**。公开 API 与诊断实现已编译，但当前探测无设备，不能判断目标手柄是否暴露 Home、系统是否转发事件或长按是否可靠。没有实机事件日志；探测输出不是手柄输入日志。完成四组测试并导出 JSON/CSV 后再据实判断 PASS / PARTIAL / FAIL。
