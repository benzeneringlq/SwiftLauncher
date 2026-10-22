import Foundation
import Darwin

struct LauncherSuggestion {
    let line: String        // full input after accepting the suggestion
    let replacement: String // completed token, used for display
}

struct LauncherEnvironmentData {
    let pathDirectories: [String]
    let executables: [String]
}

// MARK: - Login shell environment (GUI apps don't inherit the user's PATH)
final class LauncherEnvironment {
    static let shared = LauncherEnvironment()

    let shellPath: String
    private let lock = NSLock()
    private var cached: LauncherEnvironmentData?

    private init() {
        shellPath = Self.detectShell()
    }

    var data: LauncherEnvironmentData {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = Self.loadData(shell: shellPath)
        cached = loaded
        return loaded
    }

    func preload() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.data
        }
    }

    func commandNames(matching prefix: String) -> [String] {
        let names = data.executables
        guard !prefix.isEmpty else { return Array(names.prefix(300)) }
        let lower = prefix.lowercased()
        return names.filter { $0.lowercased().hasPrefix(lower) }
    }

    private static func detectShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    private static func loadData(shell: String) -> LauncherEnvironmentData {
        let directories = loginPath(shell: shell)
        return LauncherEnvironmentData(
            pathDirectories: directories,
            executables: scanExecutables(in: directories)
        )
    }

    private static func loginPath(shell: String) -> [String] {
        let fallback = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "env"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return fallback
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return fallback
        }

        for line in output.split(separator: "\n") where line.hasPrefix("PATH=") {
            let directories = line.dropFirst("PATH=".count)
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty }
            if !directories.isEmpty { return directories }
        }
        return fallback
    }

    private static func scanExecutables(in directories: [String]) -> [String] {
        let fileManager = FileManager.default
        var names = Set<String>()
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in entries where !names.contains(name) {
                let fullPath = (directory as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      fileManager.isExecutableFile(atPath: fullPath) else { continue }
                names.insert(name)
            }
        }
        return names.sorted()
    }
}

// MARK: - Completion (command position: PATH executables, otherwise: file paths)
enum LauncherCompleter {
    static func suggestions(for input: String) -> [LauncherSuggestion] {
        let context = parse(input)
        let replacementPrefix = String(input.prefix(input.count - context.rawToken.count))

        let tokens: [String]
        if context.isCommand && !context.unescapedToken.contains("/") && !context.unescapedToken.hasPrefix("~") {
            tokens = LauncherEnvironment.shared.commandNames(matching: context.unescapedToken)
        } else {
            tokens = pathCandidates(for: context.unescapedToken)
        }

        var seen = Set<String>()
        var results: [LauncherSuggestion] = []
        for token in tokens {
            let line = replacementPrefix + token
            guard line != input, seen.insert(line).inserted else { continue }
            results.append(LauncherSuggestion(line: line, replacement: token))
            if results.count >= 200 { break }
        }
        return results
    }

    static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for value in strings.dropFirst() {
            while !prefix.isEmpty && !value.hasPrefix(prefix) {
                prefix.removeLast()
            }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    private struct CompletionContext {
        let rawToken: String
        let unescapedToken: String
        let isCommand: Bool
    }

    private static func parse(_ line: String) -> CompletionContext {
        var tokenStart: String.Index?
        var completedTokens = 0
        var quote: Character?
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote != "'" {
                if tokenStart == nil { tokenStart = index }
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                if tokenStart == nil { tokenStart = index }
                quote = character
            } else if character == " " || character == "\t" {
                if tokenStart != nil {
                    completedTokens += 1
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = line.index(after: index)
        }

        let rawToken = tokenStart.map { String(line[$0...]) } ?? ""
        return CompletionContext(
            rawToken: rawToken,
            unescapedToken: unescape(rawToken),
            isCommand: completedTokens == 0
        )
    }

    private static func pathCandidates(for token: String) -> [String] {
        if token == "~" { return ["~/"] }

        let dirPart: String
        let namePrefix: String
        if token.hasSuffix("/") {
            dirPart = token
            namePrefix = ""
        } else if let slash = token.lastIndex(of: "/") {
            dirPart = String(token[...slash])
            namePrefix = String(token[token.index(after: slash)...])
        } else {
            dirPart = ""
            namePrefix = token
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let expandedDirectory: String
        if dirPart.isEmpty {
            expandedDirectory = home
        } else if dirPart.hasPrefix("~/") || dirPart == "~" {
            expandedDirectory = (dirPart as NSString).expandingTildeInPath
        } else if dirPart.hasPrefix("/") {
            expandedDirectory = dirPart
        } else {
            expandedDirectory = (home as NSString).appendingPathComponent(dirPart)
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: expandedDirectory) else { return [] }

        struct Entry {
            let name: String
            let isDirectory: Bool
        }

        let showHidden = namePrefix.hasPrefix(".")
        let lowerPrefix = namePrefix.lowercased()
        var entries: [Entry] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            guard name.lowercased().hasPrefix(lowerPrefix) else { continue }
            var isDirectory: ObjCBool = false
            let fullPath = (expandedDirectory as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { continue }
            entries.append(Entry(name: name, isDirectory: isDirectory.boolValue))
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return entries.prefix(200).map { entry in
            dirPart + escapeComponent(entry.name) + (entry.isDirectory ? "/" : "")
        }
    }

    private static func unescape(_ token: String) -> String {
        var result = ""
        var escaped = false
        var quote: Character?
        for character in token {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { result.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func escapeComponent(_ name: String) -> String {
        let specials: Set<Character> = [
            " ", "\t", "\\", "'", "\"", "`", "$", "&", ";", "|", "<", ">",
            "(", ")", "[", "]", "{", "}", "*", "?", "!", "#"
        ]
        var escaped = ""
        for character in name {
            if specials.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if escaped.hasPrefix("~") { escaped = "\\" + escaped }
        return escaped
    }
}

// MARK: - Execution
enum LauncherRunner {
    private static let processLock = NSLock()
    private static var activeProcesses: [Process] = []

    static func run(_ command: String, onFailure: @escaping (String) -> Void) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let environment = LauncherEnvironment.shared

        // 命令名对应一个 .app 时走 LaunchServices,避免直接把包内二进制当 CLI 运行
        // (否则会出现通用终端图标,且已有实例时会立即退出)
        if let parts = firstWord(of: trimmed),
           let app = appBundle(named: parts.word),
           !parts.rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { $0.hasPrefix("-") }) {
            let openCommand = parts.rest.isEmpty
                ? "open -a \(shellQuote(app.path))"
                : "open -a \(shellQuote(app.path)) \(parts.rest)"
            launch(
                executable: environment.shellPath,
                arguments: ["-l", "-c", openCommand],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                onFailure: onFailure
            )
            return
        }

        launch(
            executable: environment.shellPath,
            arguments: ["-l", "-c", command],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            onFailure: onFailure
        )
    }

    private static func firstWord(of command: String) -> (word: String, rest: String)? {
        guard let whitespace = command.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (command, "")
        }
        let word = String(command[..<whitespace])
        let rest = String(command[whitespace...]).trimmingCharacters(in: .whitespaces)
        return (word, rest)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launch(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        onFailure: @escaping (String) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let collector = ErrorCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        process.terminationHandler = { finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            release(finished)
            guard finished.terminationStatus != 0 else { return }
            let detail = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty
                ? "命令执行失败 (exit \(finished.terminationStatus))"
                : detail
            DispatchQueue.main.async { onFailure(String(message.prefix(1000))) }
        }

        retain(process)
        do {
            try process.run()
        } catch {
            release(process)
            DispatchQueue.main.async {
                onFailure("无法执行命令: \(error.localizedDescription)")
            }
        }
    }

    private static func appBundle(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains(" ") else { return nil }
        let fileManager = FileManager.default
        let directories = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
        let target = (name + ".app").lowercased()
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            if let match = entries.first(where: { $0.lowercased() == target }) {
                return URL(fileURLWithPath: directory).appendingPathComponent(match)
            }
        }
        return nil
    }

    private static func retain(_ process: Process) {
        processLock.lock()
        activeProcesses.append(process)
        processLock.unlock()
    }

    private static func release(_ process: Process) {
        processLock.lock()
        activeProcesses.removeAll { $0 === process }
        processLock.unlock()
    }
}

private final class ErrorCollector {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count < 8192 else { return }
        buffer.append(contentsOf: data.prefix(8192 - buffer.count))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}
