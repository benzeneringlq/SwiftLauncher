# SwiftLauncher

English | [简体中文](README.zh-CN.md)

A small macOS menu-bar app that combines translation, a keyboard launcher, window tiling, and a few personal shortcuts.

## Features

### Launcher (`⌥ Space`)

- Inline command completion from the login shell's `PATH`. Type `sio`, the launcher shows `sioyek`, press `Enter` to run it.
- Path completion for `~`, relative, and absolute paths, e.g. `code ~/Doc` → `code ~/Documents/`.
- `Tab` / `Shift+Tab` / `↑` / `↓` cycle through candidates, `Esc` closes the panel.
- Commands run through your login shell, so your real `PATH`, aliases, and functions work.
- Commands whose first word matches an `.app` bundle are opened through LaunchServices (flag arguments still go to the CLI), keeping the correct Dock icon and activating an existing instance instead of starting a short-lived duplicate process.
- Launcher-only window commands: `l` / `r` / `u` / `d` / `f` tile the active window.

### Translation

- `⌘⌥T` — translate the selected text with DashScope (`qwen-plus`) and show the result in a toast.
- `⌘T` — in Skim, translate the selected text with Youdao; in other apps, forward `⌘T` to the frontmost app.
- `swiftlauncher-cli "text"` sends text to the running app over a Unix socket; the result is translated with Youdao. This is used by the Sioyek integration.

API credentials are read from the macOS Keychain:

| Service | Purpose |
| --- | --- |
| `YOUDAO_APP_KEY` | Youdao translation |
| `YOUDAO_APP_SECRET` | Youdao translation |
| `DASHSCOPE_API_KEY` | DashScope / Qwen translation |

Add them with `security add-generic-password -s <service> -a "$USER" -w '<value>'`.

### Other shortcuts

- `⌘ Return` — open Alacritty.
- `⌥ ↑` / `⌥ ↓` — volume up / down.
- Runs as a menu-bar-only app (no Dock icon).

### Rime / Squirrel integration (optional)

To keep the launcher input in ASCII mode while Squirrel is in Chinese mode, add this to `~/Library/Rime/squirrel.custom.yaml` and redeploy:

```yaml
patch:
  "app_options/start4.Swiftlauncher/ascii_mode": true
```

Redeploy with `"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload`. Squirrel keys app options by the input client's bundle identifier, so it also applies to the non-activating launcher panel. If you change the app's bundle identifier, update the key.

## Requirements

- macOS 13.7 or later
- Xcode 15+ with Swift 5.9+
- `HotKey` Swift package (included as a git submodule)

## Build and Run

Clone with submodules:

```sh
git clone --recursive https://github.com/benzeneringlq/SwiftLauncher.git
cd SwiftLauncher
```

If the repository was cloned without submodules:

```sh
git submodule update --init --recursive
```

### VS Code tasks

- `Build Swiftlauncher (Release)` — default build task (`Cmd+Shift+B`).
- `Run Swiftlauncher (Release)` — build, embed/sign `swiftlauncher-cli`, and open the app.
- `Install Swiftlauncher to ~/Applications` — copy the signed app to `~/Applications`.
- `Build swiftlauncher-cli` — compile the IPC client alone.

### Manual build

```sh
xcodebuild \
  -project Swiftlauncher.xcodeproj \
  -scheme Swiftlauncher \
  -configuration Release \
  -derivedDataPath build

open build/Build/Products/Release/Swiftlauncher.app
```

The CLI is embedded into `Swiftlauncher.app/Contents/MacOS/swiftlauncher-cli`; the VS Code install task copies and ad-hoc signs it. For selected-text translation and window tiling, grant Accessibility permission in System Settings → Privacy & Security → Accessibility.

## How it works

- **Menu-bar app**: AppKit `NSStatusItem` with the `.accessory` activation policy, global hotkeys via the `HotKey` package.
- **Launcher panel**: an `NSPanel` with the `.nonactivatingPanel` style, so it can become key and accept typing without activating the app. `ToastPanel` draws inline ghost text and a candidate list, and handles `Tab` / arrows / `Enter` / `Esc`.
- **Completion**: on launch, `CommandLauncher.swift` resolves the user's login shell via `getpwuid`, runs `<shell> -l -c env` to read the real `PATH`, and scans `PATH` directories for executable names. Input is tokenized with basic quote/escape handling: the first word completes command names, later words complete filesystem paths with `~` expansion and shell escaping.
- **Execution**: commands are passed to the user's login shell (`<shell> -l -c <command>`). App bundles are launched with `open -a`, so macOS handles activation and instance management. Non-zero exits surface stderr in a toast.
- **Translation**: Youdao API with an MD5 signature, and DashScope's OpenAI-compatible chat endpoint. Results are shown in the same toast panel.
- **Window tiling**: the Accessibility API (`AXUIElement`) queries and resizes the focused window of the frontmost app.
- **IPC**: `IPC.swift` listens on a Unix domain socket (`$SWIFTHOOK_SOCKET` or a per-user temp path); messages are a 4-byte big-endian length followed by UTF-8 text.

## Project layout

```
Swiftlauncher/
├── Swiftlauncher/
│   ├── SwiftlauncherApp.swift   # app entry, hotkeys, translation, window tiling
│   ├── ToastPanel.swift         # launcher/result panel and completion UI
│   ├── CommandLauncher.swift    # login-shell env, completion, command execution
│   └── IPC.swift                # Unix socket server
├── SwiftlauncherCLI.swift       # IPC client (swiftlauncher-cli)
├── HotKey/                      # global hotkey package (submodule)
└── .vscode/tasks.json           # build / run / install tasks
```
