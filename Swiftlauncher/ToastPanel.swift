//
//  ToastPanel.swift
//  Swiftlauncher
//
//  Created by liuming on 2025/12/5.
//

import Cocoa

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
    private var currentMode: Mode = .result
    
    // 全局点击监控
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
        containerView.layer?.backgroundColor =  NSColor.black.cgColor
        containerView.layer?.cornerRadius = 10
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        self.contentView = containerView
        
        // label (多行只读)
        label.frame = NSRect(x: 20, y: 20, width: width - 40, height: height - 40)
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
        
        // inputField(默认隐藏)
        inputField.frame = NSRect(x: 20, y: (height - 36) / 2, width: width - 40, height: 36)
        inputField.font = NSFont.systemFont(ofSize: 24, weight: .medium)
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.textColor = .white
        inputField.focusRingType = .none
        inputField.isHidden = true
        inputField.delegate = self
        containerView.addSubview(inputField)
        
        setupGlobalClickMonitor()
    }
    
    deinit {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
    
    // MARK: - 全局点击监控
    private func setupGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            let mouse = NSEvent.mouseLocation
            if !self.frame.contains(mouse) {
                DispatchQueue.main.async {
                    self.hide()
                }
            }
        }
    }
    
    // MARK: - 显示 / 隐藏
    func show(mode: Mode = .result, message: String = "") {
        currentMode = mode
        
        switch mode {
        case .result:
            label.stringValue = message
            label.isHidden = false
            inputField.isHidden = true
            
            // 结果模式:直接显示,完全不激活应用
            self.orderFront(nil)
            
        case .input:
            inputField.stringValue = message
            label.isHidden = true
            inputField.isHidden = false
            inputField.isEditable = true
            inputField.isSelectable = true
            inputField.isEnabled = true
            
            // 输入模式:显示并获取焦点,但不激活应用
            // NSPanel 的 nonactivatingPanel 特性让这成为可能
            self.orderFront(nil)
            self.makeKeyAndOrderFront(nil)
            self.makeFirstResponder(inputField)
        }
    }
    
    func hide() {
        self.orderOut(nil)
        if self.firstResponder is NSTextView {
            self.makeFirstResponder(nil)
        }
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
    
    // MARK: - NSTextFieldDelegate
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        return false
    }
}
