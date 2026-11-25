//
//  ToastPanel.swift
//  Swiftlauncher
//
//  Created by liuming on 2025/12/5.
//

import Cocoa

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - ToastPanel 完全不抢焦点版本
class ToastPanel: NSPanel, NSTextFieldDelegate {

    // 关键:永远允许成为 key,但通过 NSPanel 特性不激活应用
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    enum Mode {
        case result   // 只显示结果(只读 label)
        case input    // 作为输入框(可输入)
    }

    // MARK: - 公共回调
    var onSubmit: ((String) -> Void)?

    // MARK: - 内部视图
    private let containerView = NSView()
    private let label = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let ghostLabel = NSTextField(labelWithString: "")
    private let suggestionsView = FlippedView()
    private var suggestionRows: [NSTextField] = []
    private var currentMode: Mode = .result

    // MARK: - 补全状态
    private let spotlightSearcher = SpotlightSearcher()
    private var completions: [LauncherSuggestion] = []
    private var completionBase: String?
    private var completionIndex = -1
    private var isApplyingCompletion = false

    private let resultHeight: CGFloat = 180
    private let inputHeight: CGFloat = 90
    private let rowHeight: CGFloat = 28
    private let maxVisibleRows = 8

    // 全局点击监控
    private var globalClickMonitor: Any?

    // MARK: - 初始化
    init(width: CGFloat = 1000, height: CGFloat = 180) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(
            x: (screenRect.width - width) / 2,
            y: screenRect.height - height - 100,
            width: width,
            height: height
        )

        // 关键:使用 NSPanel + nonactivatingPanel
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        commonInit(width: width, height: height)
    }

    private func commonInit(width: CGFloat, height: CGFloat) {
        // 窗口基础配置
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // 关键设置:NSPanel 特性
        self.isFloatingPanel = true
        self.level = .floating
        self.hidesOnDeactivate = false  // 不自动隐藏

        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // container view
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor
        containerView.layer?.cornerRadius = 10
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        self.contentView = containerView

        // label (多行只读)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 24, weight: .regular)
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.isEditable = false
        label.isSelectable = true
        label.isBezeled = false
        label.drawsBackground = false
        containerView.addSubview(label)

        // 补全候选列表（预先实例化固定数量视图用于复用）
        suggestionsView.wantsLayer = true
        for index in 0..<maxVisibleRows {
            let row = NSTextField(labelWithString: "")
            row.font = NSFont.systemFont(ofSize: 16, weight: .regular)
            row.textColor = NSColor.white.withAlphaComponent(0.75)
            row.lineBreakMode = .byTruncatingMiddle
            row.isHidden = true
            row.frame = NSRect(
                x: 0,
                y: CGFloat(index) * rowHeight + 4,
                width: width - 40,
                height: rowHeight - 4
            )
            suggestionsView.addSubview(row)
            suggestionRows.append(row)
        }
        containerView.addSubview(suggestionsView)

        // inputField(默认隐藏)
        inputField.font = NSFont.systemFont(ofSize: 24, weight: .medium)
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.textColor = .white
        inputField.focusRingType = .none
        inputField.usesSingleLineMode = true
        inputField.isHidden = true
        inputField.delegate = self
        containerView.addSubview(inputField)

        // 灰色行内补全提示(画在输入文字后面)
        ghostLabel.font = inputField.font
        ghostLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        ghostLabel.isEditable = false
        ghostLabel.isSelectable = false
        ghostLabel.isBezeled = false
        ghostLabel.drawsBackground = false
        ghostLabel.lineBreakMode = .byTruncatingTail
        ghostLabel.isHidden = true
        containerView.addSubview(ghostLabel)
    }

    deinit {
        removeGlobalClickMonitor()
    }

    // MARK: - 全局点击监控（按需挂载）
    private func setupGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let mouse = NSEvent.mouseLocation
            if !self.frame.contains(mouse) {
                DispatchQueue.main.async {
                    self.hide()
                }
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - 布局
    private func setPanelHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        var newFrame = frame
        newFrame.size.height = height
        newFrame.origin.y = top - height
        setFrame(newFrame, display: true)
        layoutContent()
    }

    private func layoutContent() {
        containerView.frame = NSRect(origin: .zero, size: frame.size)
        switch currentMode {
        case .result:
            label.frame = NSRect(x: 20, y: 20, width: frame.width - 40, height: frame.height - 40)
        case .input:
            inputField.frame = NSRect(x: 20, y: frame.height - 56, width: frame.width - 40, height: 36)
            updateGhostFrame()
        }
    }

    private func updateGhostFrame() {
        let font = inputField.font ?? NSFont.systemFont(ofSize: 24, weight: .medium)
        ghostLabel.font = font
        let typedWidth = (inputField.stringValue as NSString).size(withAttributes: [.font: font]).width
        let x = inputField.frame.minX + typedWidth + 2
        ghostLabel.frame = NSRect(
            x: x,
            y: inputField.frame.minY,
            width: max(0, inputField.frame.maxX - x),
            height: 36
        )
    }

    // MARK: - 显示 / 隐藏
    func show(mode: Mode = .result, message: String = "") {
        currentMode = mode
        resetCompletionState()

        switch mode {
        case .result:
            label.stringValue = message
            label.isHidden = false
            inputField.isHidden = true
            suggestionsView.isHidden = true
            setPanelHeight(resultHeight)
            layoutContent()

            // 结果模式:直接显示,完全不激活应用
            self.orderFront(nil)

        case .input:
            inputField.stringValue = message
            label.isHidden = true
            inputField.isHidden = false
            inputField.isEditable = true
            inputField.isSelectable = true
            inputField.isEnabled = true
            setPanelHeight(inputHeight)
            layoutContent()

            // 输入模式:显示并获取焦点,但不激活应用
            // NSPanel 的 nonactivatingPanel 特性让这成为可能
            self.orderFront(nil)
            self.makeKeyAndOrderFront(nil)
            self.makeFirstResponder(inputField)
            focusCaretAtEnd()
            if !message.isEmpty {
                refreshCompletions()
            }
        }

        setupGlobalClickMonitor()
    }

    func hide() {
        removeGlobalClickMonitor()
        self.orderOut(nil)
        if self.firstResponder is NSTextView {
            self.makeFirstResponder(nil)
        }
        resetCompletionState()
    }

    // MARK: - 关闭时恢复焦点到之前的应用
    override func close() {
        super.close()
        // 如果应用被激活了,隐藏它以恢复之前应用的焦点
        if NSApp.isActive {
            NSApp.hide(nil)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        hide()
    }

    override func resignKey() {
        super.resignKey()
        // 当失去 key 状态时关闭
        hide()
    }

    // MARK: - 补全
    private func resetCompletionState() {
        spotlightSearcher.cancel()
        completions = []
        completionBase = nil
        completionIndex = -1
        ghostLabel.stringValue = ""
        ghostLabel.isHidden = true
        removeSuggestionRows()
        suggestionsView.isHidden = true
    }

    private func refreshCompletions() {
        let text = inputField.stringValue
        completionBase = nil
        completionIndex = -1
        guard !text.isEmpty else {
            spotlightSearcher.cancel()
            applyCompletions([])
            return
        }

        if text.hasPrefix(" ") {
            let keyword = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !keyword.isEmpty else {
                spotlightSearcher.cancel()
                applyCompletions([])
                return
            }
            spotlightSearcher.search(keyword: keyword) { [weak self] urls in
                guard let self = self,
                      self.currentMode == .input,
                      self.inputField.stringValue.hasPrefix(" ") else { return }
                let items = urls.map { url in
                    LauncherSuggestion(
                        line: " " + url.lastPathComponent,
                        replacement: "\(url.lastPathComponent) — \(url.deletingLastPathComponent().path)",
                        action: .openFile(url)
                    )
                }
                self.applyCompletions(items, showListForSingleItem: true, showGhost: false)
            }
            return
        }

        if text == "cb" || text.hasPrefix("cb ") {
            spotlightSearcher.cancel()
            let keyword = text.hasPrefix("cb ") ? String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
            let history = ClipboardHistory.shared.items
            let filtered = keyword.isEmpty
                ? history
                : history.filter { $0.localizedCaseInsensitiveContains(keyword) }
            let items = filtered.map { content in
                let preview = content
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                return LauncherSuggestion(
                    line: text,
                    replacement: preview,
                    action: .pasteClipboard(content)
                )
            }
            applyCompletions(items, showListForSingleItem: true, showGhost: false)
            return
        }

        spotlightSearcher.cancel()
        let items = LauncherCompleter.suggestions(for: text).filter { $0.line != text }
        applyCompletions(items)
    }

    private func applyCompletions(
        _ items: [LauncherSuggestion],
        showListForSingleItem: Bool = false,
        showGhost: Bool = true
    ) {
        completions = items
        let text = inputField.stringValue

        var ghost = ""
        if showGhost {
            if items.count == 1 {
                let candidate = items[0].line
                if candidate.lowercased().hasPrefix(text.lowercased()), candidate.count > text.count {
                    ghost = String(candidate.dropFirst(text.count))
                }
            } else if items.count > 1 {
                let prefix = LauncherCompleter.commonPrefix(items.map(\.line))
                if prefix.lowercased().hasPrefix(text.lowercased()), prefix.count > text.count {
                    ghost = String(prefix.dropFirst(text.count))
                }
            }
        }

        ghostLabel.stringValue = ghost
        ghostLabel.isHidden = ghost.isEmpty
        if ghost.isEmpty {
            updateGhostFrame()
        }

        let shouldShowRows = showListForSingleItem ? !items.isEmpty : items.count > 1
        if shouldShowRows {
            rebuildSuggestionRows(Array(items.prefix(maxVisibleRows)))
            suggestionsView.isHidden = false
            setPanelHeight(inputHeight + CGFloat(min(items.count, maxVisibleRows)) * rowHeight)
        } else {
            removeSuggestionRows()
            suggestionsView.isHidden = true
            setPanelHeight(inputHeight)
        }
        layoutContent()
    }

    private func rebuildSuggestionRows(_ items: [LauncherSuggestion]) {
        let visibleCount = min(items.count, maxVisibleRows)
        suggestionsView.frame = NSRect(
            x: 20,
            y: 8,
            width: frame.width - 40,
            height: CGFloat(visibleCount) * rowHeight
        )
        for (index, row) in suggestionRows.enumerated() {
            if index < visibleCount {
                let selected = index == completionIndex
                row.textColor = NSColor.white.withAlphaComponent(selected ? 1.0 : 0.75)
                row.stringValue = (selected ? "› " : "   ") + items[index].replacement
                row.frame = NSRect(
                    x: 0,
                    y: CGFloat(index) * rowHeight + 4,
                    width: frame.width - 40,
                    height: rowHeight - 4
                )
                row.isHidden = false
            } else {
                row.isHidden = true
                row.stringValue = ""
            }
        }
    }

    private func removeSuggestionRows() {
        for row in suggestionRows {
            row.isHidden = true
            row.stringValue = ""
        }
    }

    private func markSelectedRow() {
        let visibleCount = min(completions.count, suggestionRows.count)
        for index in 0..<visibleCount {
            let row = suggestionRows[index]
            let selected = index == completionIndex
            row.textColor = NSColor.white.withAlphaComponent(selected ? 1.0 : 0.75)
            row.stringValue = (selected ? "› " : "   ") + completions[index].replacement
        }
    }

    private func cycleCompletion(forward: Bool) {
        let visibleCount = min(completions.count, maxVisibleRows)
        guard visibleCount > 0 else { return }
        if completionBase == nil {
            completionBase = inputField.stringValue
            completionIndex = forward ? 0 : visibleCount - 1
        } else {
            completionIndex = (completionIndex + (forward ? 1 : -1) + visibleCount) % visibleCount
        }

        isApplyingCompletion = true
        inputField.stringValue = completions[completionIndex].line
        isApplyingCompletion = false
        focusCaretAtEnd()
        ghostLabel.isHidden = true
        if suggestionsView.isHidden == false {
            markSelectedRow()
        }
    }

    private func focusCaretAtEnd() {
        guard let editor = inputField.currentEditor() as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (inputField.stringValue as NSString).length, length: 0))
    }

    private func selectedSpotlightURL() -> URL? {
        guard currentMode == .input, inputField.stringValue.hasPrefix(" ") else { return nil }
        let index = (completionIndex >= 0 && completionIndex < completions.count) ? completionIndex : 0
        guard index < completions.count, case .openFile(let fileURL) = completions[index].action else {
            return nil
        }
        return fileURL
    }

    @discardableResult
    func handleCommandReturn() -> Bool {
        guard isVisible, let fileURL = selectedSpotlightURL() else { return false }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return true
    }

    // MARK: - NSTextFieldDelegate
    func controlTextDidChange(_ obj: Notification) {
        guard currentMode == .input, !isApplyingCompletion else { return }
        if let editor = inputField.currentEditor() as? NSTextView, editor.hasMarkedText() {
            applyCompletions([])
            return
        }
        refreshCompletions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let selectedIndex = (completionIndex >= 0 && completionIndex < completions.count) ? completionIndex : 0
            if selectedIndex < completions.count {
                switch completions[selectedIndex].action {
                case .openFile(let fileURL):
                    let revealInFinder = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                    hide()
                    if revealInFinder {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } else {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return true
                case .pasteClipboard(let content):
                    hide()
                    ClipboardHistory.shared.copyAndPaste(content)
                    return true
                case .killProcess(let app):
                    hide()
                    if !app.forceTerminate() {
                        Darwin.kill(app.processIdentifier, SIGKILL)
                    }
                    return true
                case .command:
                    break
                }
            }

            var text = inputField.stringValue
            if completions.count == 1, !ghostLabel.isHidden {
                text = completions[0].line
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            hide()
            if !text.isEmpty {
                onSubmit?(text)
            }
            return true
        }

        if commandSelector == #selector(cancelOperation(_:)) {
            hide()
            return true
        }

        if commandSelector == #selector(insertTab(_:)) {
            cycleCompletion(forward: true)
            return true
        }

        if commandSelector == #selector(insertBacktab(_:)) {
            cycleCompletion(forward: false)
            return true
        }

        if commandSelector == #selector(moveDown(_:)) {
            cycleCompletion(forward: true)
            return true
        }

        if commandSelector == #selector(moveUp(_:)) {
            cycleCompletion(forward: false)
            return true
        }

        return false
    }
}
