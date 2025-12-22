//
//  ToastWindow.swift
//  Swiftlauncher
//
//  Created by liuming on 2025/12/4.
//

import Cocoa
// MARK: - 窗口类
class ToastWindow: NSWindow, NSTextFieldDelegate {
    
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
    enum Mode {
        case result   // 只显示结果（只读 label）
        case input    // 作为输入框（可输入）
    }
    
    // MARK: - 公共回调
    /// 输入模式下按回车会触发此回调
    var onSubmit: ((String) -> Void)?
    
    // MARK: - 内部视图
    private let containerView = NSView()
    private let label = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private var currentMode: Mode = .result
    
    // 全局点击监控（用于点外部关闭）
    private var globalClickMonitor: Any?
    
    // MARK: - 初始化
    init(width: CGFloat = 600, height: CGFloat = 120) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(
            x: (screenRect.width - width) / 2,
            y: screenRect.height - height - 100,
            width: width,
            height: height
        )
        
        super.init(contentRect: rect,
                   styleMask: [.borderless,.nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        
        commonInit(width: width, height: height)
    }
    
    private func commonInit(width: CGFloat, height: CGFloat) {
        // 窗口基础配置
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.makeKeyAndOrderFront(nil)
        self.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        
        // container view
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor
        containerView.layer?.cornerRadius = 10
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        self.contentView = containerView
        
        // label (多行只读)
        label.frame = NSRect(x: 20, y: 20, width: width - 40, height: height - 40)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        containerView.addSubview(label)
        
        // inputField（默认隐藏）
        inputField.frame = NSRect(x: 20, y: (height - 36) / 2, width: width - 40, height: 36)
        inputField.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.textColor = .white
        inputField.focusRingType = .none
        inputField.isHidden = true
        inputField.delegate = self
        containerView.addSubview(inputField)
        
        setupGlobalClickMonitor()
        // 监听按键：因 NSTextFieldDelegate 中实现 doCommandBy, ESC/Enter 会被捕获
    }
    
    deinit {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
    
    // MARK: - 全局点击监控（点窗口外就关闭）
    private func setupGlobalClickMonitor() {
        // 使用全局监控只做“点外部关闭”动作（keyboard 仍然交由 first responder）
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            let mouse = NSEvent.mouseLocation
            // 注意：window.frame 使用屏幕坐标系（原点在左下），mouseLocation 也同此坐标系
            if !self.frame.contains(mouse) {
                DispatchQueue.main.async {
                    self.hide()
                }
            }
        }
    }
    
    // MARK: - 显示 / 隐藏
    /// show 用来显示 window。mode 决定是输入模式还是结果模式
    
    func show(mode: Mode = .result, message: String = "") {
        currentMode = mode
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        switch mode {
        case .result:
            label.stringValue = message
            label.isHidden = false
            inputField.isHidden = true
        case .input:
            inputField.stringValue = message
            label.isHidden = true
            inputField.isHidden = false
            inputField.isEditable = true
            inputField.isSelectable = true
            inputField.isEnabled = true
            self.makeKeyAndOrderFront(nil)
            self.makeFirstResponder(inputField)  // 焦点给输入框
        }
        
        if mode == .result {
            self.makeKeyAndOrderFront(nil)
        }
    }
    
    func hide() {
        self.orderOut(nil)
        // 收起 first responder
        if self.firstResponder is NSTextView {
            self.makeFirstResponder(nil)
        }
    }
    
    // MARK: - NSTextFieldDelegate: 捕获 Enter / ESC
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 回车
        if commandSelector == #selector(insertNewline(_:)) {
            let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // 先 hide，再回调，避免 race
            hide()
            if !text.isEmpty {
                onSubmit?(text)
            }
            return true
        }
        
        // ESC 关闭（取消）
        if commandSelector == #selector(cancelOperation(_:)) {
            hide()
            return true
        }
        
        return false
    }
    
    // 允许点击复制 label 的文本（只读）
    override func mouseDown(with event: NSEvent) {
        // 如果是 result 模式且 label 可选中，尽量让 label 成为 first responder 的 NSTextView（保持行为一致）
        super.mouseDown(with: event)
    }
}
