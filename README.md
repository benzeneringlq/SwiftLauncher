# SwiftLauncher

English | [简体中文](README.zh-CN.md)

A small macOS menu-bar app that combines translation, a keyboard launcher, window tiling, and a few personal shortcuts.

## Features

### Launcher (`⌥ Space`)

- Inline command completion from the login shell's `PATH` (pre-sorted binary search). Type `sio`, the launcher shows `sioyek`, press `Enter` to run it.
- Path completion for `~`, relative, and absolute paths, e.g. `code ~/Doc` → `code ~/Documents/`.
- **Spotlight file search**: start input with a space (e.g. ` report.pdf`) to search files across the Mac via `NSMetadataQuery`. Press `Enter` to open the file, or `⌘ + Enter` to reveal it in Finder.
- **Clipboard history**: press `⌥ V` or type `cb [keyword]` to search the last 50 plain-text clipboard entries stored in memory. Press `Enter` to copy the selected entry back and paste (`⌘ V`).
- **Process killer**: type `kill [keyword]` to fuzzy-match running applications by name or bundle ID (with PID). Press `Enter` to terminate (`forceTerminate()`, falling back to `SIGKILL`).
- **Finder context jump**: type `term` or `here` to read the frontmost Finder window's folder path via AppleScript and open a new Alacritty window in that directory.
- `Tab` / `Shift+Tab` / `↑` / `↓` cycle through candidates, `Esc` closes the panel.
- Commands run through your login shell, so your real `PATH`, aliases, and functions work.
- Commands whose first word matches an `.app` bundle with no extra arguments are opened directly via `NSWorkspace.openApplication` (bypassing the shell); commands with file arguments still go through `open -a` and `-` flag arguments go to the CLI.
- Launcher-only window commands: `l` / `r` / `u` / `d` / `f` tile the active window on the display containing the window.

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

Add them with `security add-generic-password -s <service> -a "$USER" -w '<value>'` (if a key is missing, the translation toast prints the exact `security` command to copy and run).

### Other shortcuts

- `⌥ V` — open the in-memory clipboard history (`cb `).
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

### Build script (`build.sh`)

```sh
./build.sh          # build Swiftlauncher.app + swiftlauncher-cli, embed CLI, and sign
./build.sh cli      # build swiftlauncher-cli only
./build.sh run      # build, embed/sign, and launch Swiftlauncher.app
./build.sh install  # build, embed/sign, and copy Swiftlauncher.app to ~/Applications/
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

The CLI is embedded into `Swiftlauncher.app/Contents/MacOS/swiftlauncher-cli`; the VS Code install task copies it and re-signs the bundle. It prefers a local `Swiftlauncher Local Signing` identity (a 10-year self-signed certificate in the login keychain), then any other available identity, and falls back to ad-hoc signing. A stable identity keeps the Accessibility grant across rebuilds. For selected-text translation and window tiling, grant Accessibility permission in System Settings → Privacy & Security → Accessibility.

## How it works

- **Menu-bar app**: AppKit `NSStatusItem` with the `.accessory` activation policy, global hotkeys via the `HotKey` package.
- **Launcher panel**: an `NSPanel` with the `.nonactivatingPanel` style, so it can become key and accept typing without activating the app. `ToastPanel` reuses a fixed pool of 8 row views, attaches its global click monitor only while visible, and handles `Tab` / arrows / `Enter` / `Esc`.
- **Completion & Search**: on launch, `CommandLauncher.swift` resolves the user's login shell via `getpwuid`, runs `<shell> -l -c env` to read the real `PATH`, and builds a lowercase-sorted executable index for $O(\log N)$ prefix binary search. Path completion prefetches `.isDirectoryKey` via `contentsOfDirectory(at:includingPropertiesForKeys:options:)`. Leading-space queries route to `SpotlightSearcher` (`NSMetadataQuery`), `cb` queries `ClipboardHistory` (50-item in-memory ring buffer), and `kill` queries `NSWorkspace.shared.runningApplications`.
- **Execution**: `.app` bundles with no arguments open directly via `NSWorkspace.shared.openApplication`; other commands run through the user's login shell (`<shell> -l -c <command>`). Non-zero exits surface stderr in a toast.
- **Translation**: Youdao API with an MD5 signature, and DashScope's OpenAI-compatible chat endpoint. Results are shown in the same toast panel.
- **Window tiling**: the Accessibility API (`AXUIElement`) reads the focused window's position and size to locate its display in `NSScreen.screens`, then tiles within that display's `visibleFrame`.
- **IPC**: `IPC.swift` listens on a Unix domain socket (`$SWIFTHOOK_SOCKET` or a per-user temp path); messages are a 4-byte big-endian length followed by UTF-8 text.

## Project layout

```
Swiftlauncher/
├── Swiftlauncher/
│   ├── SwiftlauncherApp.swift   # app entry, hotkeys, translation, window tiling, Finder jump
│   ├── ToastPanel.swift         # launcher/result panel, completion UI, input routing
│   ├── CommandLauncher.swift    # env, completion, runner, SpotlightSearcher, ClipboardHistory
│   └── IPC.swift                # Unix socket server
├── SwiftlauncherCLI.swift       # IPC client (swiftlauncher-cli)
├── build.sh                     # CLI build / run / install script
├── HotKey/                      # global hotkey package (submodule)
└── .vscode/tasks.json           # build / run / install tasks
```
