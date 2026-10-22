# SwiftLauncher

[English](README.md) | 简体中文

一个轻量的 macOS 菜单栏工具，集成了翻译、键盘启动器、窗口平铺和几个个人快捷键。

## 功能

### 启动器（`⌥ Space`）

- 基于登录 shell `PATH` 的行内命令补全。输入 `sio` 会出现 `sioyek`，回车即可运行。
- 支持 `~`、相对路径和绝对路径补全，例如 `code ~/Doc` → `code ~/Documents/`。
- `Tab` / `Shift+Tab` / `↑` / `↓` 切换候选，`Esc` 关闭面板。
- 命令通过你的登录 shell 执行，因此真实的 `PATH`、alias 和函数都能生效。
- 命令名匹配到 `.app` 时改走 LaunchServices（带 `-` 参数时仍交给 CLI）：保留正确的 Dock 图标，并激活已有实例，而不是启动一个马上退出的重复进程。
- 启动器内可用 `l` / `r` / `u` / `d` / `f` 平铺当前活动窗口。

### 翻译

- `⌘⌥T` — 用 DashScope（`qwen-plus`）翻译选中文本，结果以浮层显示。
- `⌘T` — 在 Skim 中翻译选中文本（有道）；在其他应用中则向前台应用转发 `⌘T`。
- `swiftlauncher-cli "text"` 通过 Unix socket 把文本发给正在运行的应用，再用有道翻译。Sioyek 的联动就是用它。

API 凭据从 macOS Keychain 读取：

| Service | 用途 |
| --- | --- |
| `YOUDAO_APP_KEY` | 有道翻译 |
| `YOUDAO_APP_SECRET` | 有道翻译 |
| `DASHSCOPE_API_KEY` | DashScope / Qwen 翻译 |

添加方式：`security add-generic-password -s <service> -a "$USER" -w '<value>'`。

### 其他快捷键

- `⌘ Return` — 打开 Alacritty。
- `⌥ ↑` / `⌥ ↓` — 音量加 / 减。
- 仅作为菜单栏应用运行，不显示 Dock 图标。

### Rime / Squirrel 联动（可选）

希望松鼠处于中文模式时，启动器输入仍为 ASCII，可在 `~/Library/Rime/squirrel.custom.yaml` 中加入以下配置并重新部署：

```yaml
patch:
  "app_options/start4.Swiftlauncher/ascii_mode": true
```

重新部署：`"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload`。Squirrel 按输入客户端的 bundle identifier 匹配 app_options，所以对非激活的启动器面板同样生效。如果修改了应用的 bundle identifier，记得同步改这里的 key。

## 环境要求

- macOS 13.7 或更高版本
- Xcode 15+，Swift 5.9+
- `HotKey` Swift 包（已作为 git submodule 引入）

## 构建与运行

带 submodule 克隆：

```sh
git clone --recursive https://github.com/benzeneringlq/SwiftLauncher.git
cd SwiftLauncher
```

如果克隆时没带 submodule：

```sh
git submodule update --init --recursive
```

### VS Code 任务

- `Build Swiftlauncher (Release)` — 默认构建任务（`Cmd+Shift+B`）。
- `Run Swiftlauncher (Release)` — 构建、嵌入并签名 `swiftlauncher-cli`，然后打开应用。
- `Install Swiftlauncher to ~/Applications` — 把签名后的 app 复制到 `~/Applications`。
- `Build swiftlauncher-cli` — 单独编译 IPC 客户端。

### 手动构建

```sh
xcodebuild \
  -project Swiftlauncher.xcodeproj \
  -scheme Swiftlauncher \
  -configuration Release \
  -derivedDataPath build

open build/Build/Products/Release/Swiftlauncher.app
```

CLI 会被嵌入到 `Swiftlauncher.app/Contents/MacOS/swiftlauncher-cli`；VS Code 的安装任务负责复制并 ad-hoc 签名。使用选中文本翻译和窗口平铺前，需要在“系统设置 → 隐私与安全性 → 辅助功能”中授予权限。

## 实现简述

- **菜单栏应用**：AppKit `NSStatusItem` + `.accessory` 激活策略，全局热键由 `HotKey` 包注册。
- **启动器面板**：使用带 `.nonactivatingPanel` 样式的 `NSPanel`，可以在不激活应用的情况下成为 key window 并接收输入。`ToastPanel` 负责绘制行内灰色补全提示、候选列表，以及处理 `Tab` / 方向键 / `Enter` / `Esc`。
- **补全**：启动时 `CommandLauncher.swift` 通过 `getpwuid` 找到用户的登录 shell，执行 `<shell> -l -c env` 读取真实 `PATH`，再扫描各目录中的可执行文件。输入会做基本的引号和转义解析：第一个词补全命令名，后续词补全文件路径，支持 `~` 展开和 shell 转义。
- **执行**：命令交给登录 shell（`<shell> -l -c <command>`）。匹配到 app bundle 时用 `open -a` 交给 LaunchServices，由 macOS 负责激活和实例管理。命令退出码非 0 时，stderr 会以浮层显示。
- **翻译**：有道 API（MD5 签名）和 DashScope 的 OpenAI 兼容接口，结果复用同一个浮层显示。
- **窗口平铺**：通过辅助功能 API（`AXUIElement`）读取并调整前台应用的焦点窗口。
- **IPC**：`IPC.swift` 监听 Unix domain socket（`$SWIFTHOOK_SOCKET` 或按用户生成的临时路径），消息格式为 4 字节大端长度 + UTF-8 文本。

## 项目结构

```
Swiftlauncher/
├── Swiftlauncher/
│   ├── SwiftlauncherApp.swift   # 应用入口、热键、翻译、窗口平铺
│   ├── ToastPanel.swift         # 启动器/结果面板与补全 UI
│   ├── CommandLauncher.swift    # 登录 shell 环境、补全、命令执行
│   └── IPC.swift                # Unix socket 服务端
├── SwiftlauncherCLI.swift       # IPC 客户端（swiftlauncher-cli）
├── HotKey/                      # 全局热键包（submodule）
└── .vscode/tasks.json           # 构建 / 运行 / 安装任务
```
