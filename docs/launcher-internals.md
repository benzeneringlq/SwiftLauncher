# Launcher 补全与执行实现

本文说明 `⌥Space` 启动器的补全与命令执行机制，对应代码：

- `Swiftlauncher/CommandLauncher.swift`
- `Swiftlauncher/ToastPanel.swift`
- `Swiftlauncher/SwiftlauncherApp.swift`

## 1. 概览

- **补全**：原生 Swift 实现，只提供两类候选——PATH 中的可执行文件名、文件系统路径。
- **执行**：把整条命令交给用户的登录 shell，以 `<shell> -l -c <command>` 运行。
- **环境**：登录 shell 的 PATH 只在启动时加载一次，之后缓存。
- **不是终端**：没有 TTY，stdout 被丢弃，只捕获 stderr 用于失败提示。

```text
⌥Space
  → ToastPanel（输入模式）
    → 每次输入变化 → LauncherCompleter
        ├─ 第 1 个 token → PATH 可执行文件
        └─ 第 2+ 个 token → 文件系统路径
  → Enter
    → handleLauncherCommand
      → LauncherRunner
        ├─ 能匹配 .app → open -a（LaunchServices）
        └─ 其他 → <login shell> -l -c <command>
```

## 2. 环境加载

`LauncherEnvironment` 是单例，负责找到登录 shell 并读取它真实的 PATH。

1. `detectShell()` 用 `getpwuid(getuid())` 读 `pw_shell`；不可执行时回退 `$SHELL`，最后回退 `/bin/zsh`。
2. `loginPath()` 执行 `<shell> -l -c env`，从输出里解析 `PATH=`，按 `:` 拆成目录列表。
   - 这是必要的：从 Finder/Spotlight 启动的 GUI app 不会继承终端里的 PATH。
   - 失败时回退到 app 进程自己的 PATH。
3. `scanExecutables()` 遍历这些目录：
   - 跳过子目录；
   - 只保留 `isExecutableFile` 为 true 的文件；
   - 去重后排序。
4. `preload()` 在 `.utility` 后台队列触发一次加载；`data` 用 `NSLock` 保护缓存。

注意：

- 扫描的是目录里的“可执行文件名”，不会枚举 `.app` bundle。因此 `sioyek`、`code` 这类在 PATH 中有入口的命令能补全；只存在于 `/Applications` 的纯 GUI app 不会出现在命令候选里（执行时仍可被 `appBundle(named:)` 识别）。
- PATH 缓存不会自动刷新；修改 fish 配置后需要重启 app。

## 3. 补全

### 3.1 Token 解析

`LauncherCompleter.parse` 逐字符扫描当前输入，处理：

- 反斜杠转义（单引号内不转义）；
- 单引号/双引号；
- 以空格或 tab 分隔的 token；
- 当前正在编辑的 `rawToken` 与去掉引号/转义后的 `unescapedToken`；
- `completedTokens == 0` 表示当前 token 处于命令位置。

### 3.2 命令位置

当 token 在命令位置，且不含 `/`、不以 `~` 开头时：

- 在缓存的 PATH 可执行文件名中做大小写不敏感的前缀匹配；
- 空前缀返回前 300 个；
- 结果最多保留 200 条，并去掉与当前输入完全相同的候选。

例如输入 `cod` 会匹配到 `code`，`sio` 会匹配到 `sioyek`。

### 3.3 路径位置

其他 token 走 `pathCandidates`：

1. 以最后一个 `/` 拆成 `dirPart` 和 `namePrefix`；没有 `/` 时目录为 home。
2. 展开 `~/`；绝对路径直接使用；相对路径拼到 home 下（与 Runner 的工作目录一致）。
3. `contentsOfDirectory` 列出目录，过滤：
   - 普通文件/目录名是否以 `namePrefix` 开头（大小写不敏感）；
   - 隐藏文件只在 prefix 以 `.` 开头时显示；
   - `fileExists(isDirectory:)` 判断是否为目录。
4. 排序：目录优先，然后按本地化自然顺序。
5. 目录补 `/`，shell 特殊字符加反斜杠转义（空格、引号、`$`、`;`、`|`、`*` 等）。
6. 最多返回 200 条。

### 3.4 浮层交互

`ToastPanel.controlTextDidChange` 每次输入变化调用补全（输入法有 marked text 时跳过）：

- 唯一候选：在输入框后显示灰色 ghost 后缀；
- 多个候选：显示候选列表，并用公共前缀作为 ghost；
- `Tab` / `Shift-Tab` / 上下方向键在候选中循环；
- `Enter`：若只有一个候选且 ghost 可见，先接受补全再提交；否则提交当前原始文本；
- `Esc` 关闭。

## 4. 执行

`handleLauncherCommand` 先处理 `l/r/f/d/u` 窗口移动，其余交给 `LauncherRunner.run`。

`LauncherRunner.run` 的逻辑：

1. 取第一个词。如果它不含 `/`、空格，且在 `/Applications`、`/System/Applications`、`/System/Applications/Utilities`、`~/Applications` 中能找到同名 `.app`，则构造：
   ```text
   open -a '<app path>' <rest>
   ```
   交给登录 shell 执行。这样由 LaunchServices 负责激活已有实例、保留 app 图标，避免直接把包内二进制当 CLI 运行。
2. 如果 rest 中含有以 `-` 开头的参数，则不走 `open -a`，回退到普通 shell 执行（避免把 app 参数误当 `open` 参数）。
3. 其他情况执行：
   ```text
   <login shell> -l -c <原始命令>
   ```
   工作目录固定为 home。

`launch` 的细节：

- stdin 为 `/dev/null`，stdout 丢弃；
- stderr 通过 `Pipe` 异步收集，最多 8KB；
- 进程非 0 退出时，把 stderr（最多 1000 字符）或 `命令执行失败 (exit N)` 显示在浮层；
- 进程对象被持有到退出，避免提前释放。

限制：没有 TTY，`vim`、`top` 这类交互式命令无法正常使用；长时间运行、需要看 stdout 的命令也不适合放在这里。

## 5. 和 fish 的关系

在这台机器上：

```text
登录 shell: /opt/local/bin/fish
fish 版本: 4.5.0
```

- **执行是 fish**：命令通过 `fish -l -c` 运行，所以 fish 语法、管道、重定向、glob、变量、`~` 展开，以及 config 中定义的函数/别名都生效。
- **abbr 不生效**：fish abbreviation 只在交互式命令行展开。实测 `fish -c 'abbr -a testabbr echohello; testabbr'` 会报 `Unknown command`，因此不要在 launcher 命令里依赖 abbr。
- **补全不是 fish**：没有调用 `complete -C`，所以：
  - 不提供 git 分支、ssh 主机、命令选项等 fish 补全；
  - fish 的 alias/function/abbr 不会出现在候选列表；
  - 只有真实存在于 PATH 的可执行文件名会出现在命令候选里。
- 这样分层的目的是：补全不付 fish 启动成本（此前测试 fish 补全约 0.78s），执行仍保持用户 shell 的语义。

## 6. `code ~/projects` 的完整流程

1. 输入 `code ` 后，`controlTextDidChange` 调用补全。
2. `parse` 识别出第一个 token `code` 是命令位置。
3. `commandNames(matching: "code")` 在缓存的可执行文件中过滤，找到 `/usr/local/bin/code`（指向 VS Code 的 CLI）。
4. 空格后输入 `~/projects`，进入路径补全：
   - 拆成 `dirPart = "~/"`、`namePrefix = "projects"`；
   - `~/` 展开为 home；
   - 列出 home，过滤以 `projects` 开头的名字；
   - 若 `~/projects` 是目录，候选为 `~/projects/`（补斜杠）。
5. 唯一候选时显示 ghost `~/projects/`；若有多个（如 `projects-old`），显示列表，Tab 切换。
6. 按 Enter：
   - 唯一候选：接受补全，提交 `code ~/projects/`；
   - 多候选：直接提交当前文本 `code ~/projects`。
7. `handleLauncherCommand` → `LauncherRunner.run`。
8. Runner 发现第一个词是 `code`，但不存在 `code.app`，所以走普通分支：
   ```text
   fish -l -c "code ~/projects/"
   ```
   fish 展开 `~`，按 PATH 找到 `code` 这个软链接，调用 VS Code CLI 打开文件夹。
9. `code` 退出码为 0 时静默；非 0 时 stderr 显示在浮层。

补充：即使不按补全、直接回车，fish 也会展开 `~`，所以 `code ~/projects` 本身就能工作；补全只是帮助发现和输入路径。

## 7. 性能

开发机实测（26 个 PATH 目录、3338 个可执行文件；独立 `-O` 测试程序，仅作参考）：

| 操作 | 耗时 |
|---|---|
| 首次环境加载（fish env + PATH 扫描） | **~741ms** |
| 其中 fish 登录启动 | 150–260ms |
| 命令名补全（`cod`） | **~0.31ms/次** |
| 路径补全（`code ~/proj`） | **~1.67ms/次** |
| 列出 44 项的目录（`code ~/projects/`） | **~2.33ms/次** |

结论：

- 预加载在后台完成，之后补全都是内存/本地文件操作，日常输入延迟约 0.3–2ms，基本无感。
- 预加载本身约 0.7s，主要成本是 fish 启动（150–260ms）和逐项 `fileExists`/`isExecutableFile` 扫描。
- 主要风险：
  1. app 刚启动、预加载未完成时立刻呼出补全，主线程会在 `NSLock` 上等待加载完成（最多约 0.7s）。
  2. 路径补全在主线程同步执行，且对每个匹配项调用 `fileExists`；超大目录、网络盘或 iCloud 目录可能造成输入卡顿。200 条上限是在扫描/排序之后截断的，不能降低扫描成本。
  3. 环境缓存不会刷新，PATH 变更需要重启 app。
  4. 每条命令都要启动一次 fish（150–260ms 额外延迟）；`open -a` 分支目前也经过 fish。
  5. stdout 被丢弃、没有 TTY，不适合交互式或长期运行命令。

## 8. 可选优化

- 环境扫描：用 `URLResourceValues`/`getattrlistbulk` 批量取元数据，减少 stat 次数；或缓存扫描结果，启动时直接加载。
- 预加载：提高 QoS，或在首次触发补全时异步加载并显示 loading 状态，避免主线程等待。
- 路径补全：异步 + 防抖 + 目录列表缓存；用 generation token 丢弃过期结果。
- 命令名过滤：预计算小写名字，避免每次 `lowercased()` 分配。
- `open -a`：直接启动 `/usr/bin/open`，不经过 fish，减少一次 shell 启动。
- fish 风格补全：按需调用 `fish -c 'complete -C ...'` 并缓存结果，但要接受首次几百毫秒的启动成本。

## 9. 代码索引

- 环境检测/加载：`CommandLauncher.swift:15-121`
- Token 解析与补全：`CommandLauncher.swift:125-296`
- 命令执行：`CommandLauncher.swift:299-420`
- 输入框补全状态与 Enter 处理：`ToastPanel.swift:377-396`
- 启动时预加载：`SwiftlauncherApp.swift:448`
- 命令分发：`SwiftlauncherApp.swift:226-233`

行号会随代码变化，仅作定位参考。
