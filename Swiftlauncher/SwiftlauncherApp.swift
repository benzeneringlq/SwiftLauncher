// SwiftlauncherApp.swift
import SwiftUI
import HotKey
import UserNotifications
//import AppKit
import CryptoKit
import Security
import ApplicationServices
import IOKit.hid
import Cocoa
// MARK: - 配置有道 API
func getKeychainValue(service: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecAttrAccessGroup as String: "start4.com.yourcompany.yourapp"
    ]
    
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    
    if status == errSecSuccess, let data = item as? Data,
       let value = String(data: data, encoding: .utf8) {
        return value
    } else {
        print("Keychain error: \(status)")
        return nil
    }
}
//let appKey = ProcessInfo.processInfo.environment["YOUDAO_APP_KEY"] ?? ""
//let appSecret = ProcessInfo.processInfo.environment["YOUDAO_APP_SECRET"] ?? ""
let appKey = getKeychainValue(service: "YOUDAO_APP_KEY") ?? ""
let appSecret = getKeychainValue(service: "YOUDAO_APP_SECRET") ?? ""
let apiKey = getKeychainValue(service: "DASHSCOPE_API_KEY") ?? ""

func getSelectedText() -> String? {
    let systemWideElement = AXUIElementCreateSystemWide()
    
    var selectedTextValue: AnyObject?
    let errorCode = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &selectedTextValue)
    
    if errorCode == .success {
        let selectedTextElement = selectedTextValue as! AXUIElement
        var selectedText: AnyObject?
        let textErrorCode = AXUIElementCopyAttributeValue(selectedTextElement, kAXSelectedTextAttribute as CFString, &selectedText)
        
        if textErrorCode == .success, let selectedTextString = selectedText as? String {
            return selectedTextString
        } else {
            return nil
        }
    } else {
        return nil
    }
}

// MARK: - DashScope Chat Completion (Swift Version)
func dashscopeChatCompletion(userText: String, completion: @escaping (String) -> Void) {
    
    let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    
    let body: [String: Any] = [
        "model": "qwen-plus",
        "messages": [
            ["role": "system", "content": "请直接翻译为中文,只输出中文翻译:"],
            ["role": "user", "content": userText]
        ]
    ]
    
    let jsonData = try! JSONSerialization.data(withJSONObject: body)
    
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = jsonData
    
    URLSession.shared.dataTask(with: req) { data, response, error in
        guard let data = data, error == nil else {
            completion("网络错误: \(error?.localizedDescription ?? "unknown")")
            return
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            completion(content)
        } else {
            completion("解析失败")
        }
    }.resume()
}
// MARK: - 模拟系统音量键事件
func simulateVolumeKey(up: Bool, fine: Bool = true) {
    let keyCode: Int = up ? 0 : 1  // 直接使用 Int
    
    var flags = NSEvent.ModifierFlags(rawValue: 0xa00)
    if fine {
        flags.insert([.shift, .option])
    }
    
    let keyDown = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSPoint.zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: ((keyCode << 16) | (0xa << 8)),
        data2: -1
    )
    
    let keyUp = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSPoint.zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: ((keyCode << 16) | (0xb << 8)),
        data2: -1
    )
    
    keyDown?.cgEvent?.post(tap: .cghidEventTap)
    keyUp?.cgEvent?.post(tap: .cghidEventTap)
}
// MARK: - 显示通知
func showNotification( title: String,  body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    
    let request = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
// MARK: - 生成签名
func generateSign(q: String, salt: Int) -> String {
    let raw = "\(appKey)\(q)\(salt)\(appSecret)"
    let data = Data(raw.utf8)
    let digest = Insecure.MD5.hash(data: data)
    return digest.map { String(format: "%02hhx", $0) }.joined().uppercased()
}

// MARK: - App Entry
@main
struct SwiftlauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 不显示任何窗口
        Settings {} // 空 Scene，用于 Settings 面板，如果不需要可以留空
    }
}



// MARK: - HotKey Manager
class HotKeyManager: ObservableObject {
    private var hotKey: HotKey?
    private var hotKeyQwen: HotKey?
    private var volumeUpHotKey: HotKey?
    private var volumeDownHotKey: HotKey?
    // MARK: - setupHotKey
    func setupHotKey() {
        // 请求通知权限
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { print("Notification authorized") }
        }
        
        // 注册全局热键 ⌘ + T
        hotKey = HotKey(key: .t, modifiers: [.command])
        hotKey?.keyDownHandler = { [weak self] in
            guard let self = self else { return }
            self.handleHotKey()
        }
        // 注册全局热键  ⌘ + option + T 触发 qwen
        hotKeyQwen = HotKey(key: .t, modifiers: [.command, .option])
        hotKeyQwen?.keyDownHandler = { [weak self] in
            guard let self = self else { return }
            guard let selectedText = getSelectedText(), !selectedText.isEmpty else { return }
            
            dashscopeChatCompletion(userText: selectedText) { result in
                self.showTranslationToast(result)
            }
        }
        // 2️⃣ 音量增加 ⌘ + Option + ↑
        volumeUpHotKey = HotKey(key: .upArrow, modifiers: [.option])
        volumeUpHotKey?.keyDownHandler = {
            print("up")
            simulateVolumeKey(up: true)
        }
        
        // 3️⃣ 音量减少 ⌘ + Option + ↓
        volumeDownHotKey = HotKey(key: .downArrow, modifiers: [ .option])
        volumeDownHotKey?.keyDownHandler = {
            simulateVolumeKey(up: false)
        }
        
    }
    
    private func handleHotKey() {
        guard let selectedText = getSelectedText(), !selectedText.isEmpty else {
            //            showNotification(title: "翻译", body: "请先选中文本")
            return
        }
        
        // 调用翻译(只显示最终结果)
        translate(text: selectedText) { result in
//            showNotification(title: "翻译", body: result)
            self.showTranslationToast(result)
        }
    }
    // MARK: - 翻译
    private func translate(text: String, from: String = "auto", to: String = "zh-CHS", completion: @escaping (String) -> Void) {
        guard !appKey.isEmpty && !appSecret.isEmpty else {
            completion("Missing YOUDAO_APP_KEY or YOUDAO_APP_SECRET")
            return
        }
        
        let salt = Int(Date().timeIntervalSince1970)
        let sign = generateSign(q: text, salt: salt)
        var components = URLComponents(string: "https://openapi.youdao.com/api")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "appKey", value: appKey),
            URLQueryItem(name: "salt", value: String(salt)),
            URLQueryItem(name: "sign", value: sign)
        ]
        
        let request = URLRequest(url: components.url!)
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil else {
                completion("Error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let translation = json["translation"] as? [String] {
                completion(translation.joined(separator: " "))
            } else {
                completion("Translation failed")
            }
        }.resume()
    }
    private func showTranslationToast(_ text: String) {
        DispatchQueue.main.async {
            let toast = ToastWindow(message: text)
            toast.show()
        }
    }
}

import Cocoa
// MARK: - 窗口类
class ToastWindow: NSWindow {
    private static var globalClickMonitor: Any?
    private static var activeToasts: Set<ToastWindow> = []
    private static let lock = NSLock()
    
    init(message: String) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 400, height: 100)
        let width: CGFloat = 600
        let height: CGFloat = 240
        let rect = NSRect(
            x: (screenRect.width - width) / 2,
            y: screenRect.height - height - 100,
            width: width,
            height: height
        )
        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.transient, .ignoresCycle]
        
        // 使用硬件加速的 layer-backed view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        containerView.layer?.cornerRadius = 10
        
        // 使用 NSTextField 但优化配置
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 20, y: 20, width: width - 40, height: height - 40)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        label.alignment = .left
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping   // 按单词换行
        label.usesSingleLineMode = false        // 允许多行
        label.maximumNumberOfLines = 0          // 不限制行数
        containerView.addSubview(label)
        
        self.contentView = containerView
    }
    
    func show() {
        Self.lock.lock()
        Self.activeToasts.insert(self)
        
        // 只在第一个 toast 时创建全局监听器
        if Self.globalClickMonitor == nil {
            Self.setupGlobalMonitor()
        }
        Self.lock.unlock()
        
        self.orderFront(nil)
    }
    
    private static func setupGlobalMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            let mouseLocation = NSEvent.mouseLocation
            
            Self.lock.lock()
            let toastsToClose = Self.activeToasts.filter { !$0.frame.contains(mouseLocation) && $0.isVisible }
            Self.lock.unlock()
            
            // 批量关闭
            toastsToClose.forEach { $0.close() }
        }
    }
    
    override func close() {
        Self.lock.lock()
        Self.activeToasts.remove(self)
        
        // 如果没有活动的 toast 了，移除全局监听器
        if Self.activeToasts.isEmpty, let monitor = Self.globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            Self.globalClickMonitor = nil
        }
        Self.lock.unlock()
        
        super.close()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用为“辅助”类型，不显示 Dock 图标
            NSApp.setActivationPolicy(.accessory)
        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "WindowManager")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu

        // 初始化 HotKeyManager
        hotKeyManager = HotKeyManager()
        hotKeyManager?.setupHotKey()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
