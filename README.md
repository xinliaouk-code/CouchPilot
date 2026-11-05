# CouchPilot

CouchPilot 是一个原生 macOS 菜单栏工具。它用 GameController 读取手柄，在手柄模式和桌面鼠标模式之间切换。八方向轮盘是临时面板。

## 安装与运行

P1 需要 macOS 14 或更新版本。用 Xcode 打开 `CouchPilot.xcodeproj`，选择 CouchPilot scheme。也可以从项目目录构建：

```sh
xcodebuild -project CouchPilot.xcodeproj -scheme CouchPilot -configuration Release -derivedDataPath build build
```

在 Finder 中把 `build/Build/Products/Release/CouchPilot.app` 复制到「应用程序」，再手动打开。当前构建使用本地临时签名，适合本机测试。使用同一安装路径测试，重新构建或移动后如授权失效，在系统设置中重新选取该 App。

## 使用

- 默认全局手柄入口是同时按住 **LB + RB + Menu/Start 700ms**。也可点击菜单栏手柄图标或按 **Control + Option + Space**。组合键可在设置中重新学习。Home 默认只记录诊断，可在「触发」页手动启用长按呼出实验。
- 左摇杆回中后选方向，回中会保留高亮。A 确认，B 关闭整个轮盘，LB 返回上一级。应用列表也支持方向键和左右拨动摇杆。松开触发键后轮盘保持显示。
- 北起顺时针依次为运行中应用、鼠标模式、手柄模式、收藏应用、上一应用、Finder、默认浏览器、设置。默认浏览器按应用打开或激活。
- 鼠标模式下，左摇杆移动、右摇杆滚动，A 左键和拖动，B 右键，LB 精细移动，RB 快速移动，X 发 Escape，Y 发 Enter。切换模式后先松开操作键并让摇杆回中。自定义组合键若包含 A/B/X/Y，相应的鼠标映射会让给组合键。
- 右键点击菜单栏图标打开设置或退出。设置支持登录时打开、默认启动模式、触发阈值、快捷键、缩放、显示器、鼠标速度与收藏排序。运行中的应用按本次会话的激活历史排序。未观察到的应用按名称排序。

## 权限与兼容性

鼠标与键盘事件生成需要「系统设置 → 隐私与安全性 → 辅助功能」授权。设置的「鼠标」页提供跳转和重新检查入口。授权前可以继续使用轮盘和原生手柄模式。登录项由 macOS 管理，设置页显示注册结果及是否需要在系统设置中批准。

后台监听使用 GameController，实体输入仍可能到达前台游戏。Home 的系统手势偏好可以在设置里请求禁用，实际转发仍由 macOS 决定。如果 Home 不可用，使用键盘快捷键或菜单栏。面板使用非激活窗口，可尝试在常见全屏 Space 显示，覆盖能力由系统和前台应用决定。如轮盘在全屏中不可见，先通过快捷键关闭，再回普通桌面用菜单栏或快捷键打开。鼠标事件投递由系统决定，权限在拖动期间被撤销或进程被强制结束时，App 无法保证系统收到释放事件。

## Home 打开 Spotlight 或无法呼出轮盘

1. 在「系统设置 → 游戏手柄 → Home Button」关闭 **Enable Home Button Actions**。如果仅在某个应用出现，检查同页的 **Home Button Overrides**。这会调整 macOS 的 Home 动作，后台输入仍需实测。
2. 在 CouchPilot「设置 → 触发」启用「监听后台手柄事件」。如需测试用 Home 呼出，还需启用「用 Home 长按呼出轮盘（实验）」，默认阈值为 600ms。macOS 27 上可从这里打开系统 Home 设置。可以勾选「请求禁用 Home 系统手势」以测试应用偏好。
3. 先点击菜单栏图标验证轮盘。关闭轮盘后，在 CouchPilot 前台长按 Home 约一秒，然后在 Safari 前台重复。诊断页打开「仅显示 Home 和菜单触发」，比对 press、release、持续时间和 trigger。若前台有输入而后台没有，使用键盘或手柄组合键呼出。

## 诊断

设置的「诊断」页保留 P0 的实时输入、四组 Controller Shortcuts 手动记录，以及 JSON/CSV 导出。可过滤只看 Home 和菜单触发，导出仍包含整个会话。事件中的 `appState` 表示 CouchPilot 前后台，触发记录中的 `frontmost` 是当时系统报告的前台应用。Home 释放持续时间取自单调时钟。P0 固定 600ms 的诊断阈值和 P1 的可调菜单触发阈值分别记录。

测试后台 Home 时，在 Safari、Finder 或另一普通 App 前台分别短按和长按，再查看 `Home` 的 press、threshold、release 及 trigger 记录。同时人工观察 Games/Spotlight 是否出现，分别记录 Controller Shortcuts 开关与 Home 手势偏好。导出后退出可保留证据。完整的 P1 验收矩阵见 [P1 验收记录](P1_ACCEPTANCE.md)。

命令行状态检查可以在不打开 App 的情况下运行：

```sh
tests/run-state-checks.sh
```
