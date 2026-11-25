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
        kSecMatchLimit as String: kSecMatchLimitOne
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
let appKey = getKeychainValue(service: "YOUDAO_APP_KEY") ?? ""
let appSecret = getKeychainValue(service: "YOUDAO_APP_SECRET") ?? ""
let apiKey = getKeychainValue(service: "DASHSCOPE_API_KEY") ?? ""
let launcherToast = ToastPanel()
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
    guard !apiKey.isEmpty else {
        completion("缺Key! 终端运行:\nsecurity add-generic-password -s DASHSCOPE_API_KEY -a $USER -w <YOUR_KEY>")
        return
    }

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

// MARK: - 移动窗口
func moveActiveWindow(direction: String) {
    // 获取当前激活的应用
    let workspace = NSWorkspace.shared
    guard let activeApp = workspace.frontmostApplication else { return }
    
    // 使用 Accessibility API 获取窗口
    let app = AXUIElementCreateApplication(activeApp.processIdentifier)
    var windowRef: CFTypeRef?
    
    // 获取焦点窗口
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
    
    guard let window = windowRef else { return }
    let axWindow = window as! AXUIElement

    // 从 Accessibility API 读取窗口当前位置与尺寸，计算窗口中心点所在的屏幕
    var posRef: CFTypeRef?
    var sizeRefCurrent: CFTypeRef?
    var currentPosition = CGPoint.zero
    var currentSize = CGSize.zero
    let hasPosition = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success
        && posRef != nil
        && AXValueGetValue(posRef as! AXValue, .cgPoint, &currentPosition)
    let hasSize = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRefCurrent) == .success
        && sizeRefCurrent != nil
        && AXValueGetValue(sizeRefCurrent as! AXValue, .cgSize, &currentSize)

    let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    let targetScreen: NSScreen?
    if hasPosition && hasSize {
        let axCenter = CGPoint(
            x: currentPosition.x + currentSize.width / 2,
            y: currentPosition.y + currentSize.height / 2
        )
        let cocoaCenter = CGPoint(x: axCenter.x, y: primaryHeight - axCenter.y)
        if let matched = NSScreen.screens.first(where: { $0.frame.contains(cocoaCenter) }) {
            targetScreen = matched
        } else {
            let cocoaRect = CGRect(
                x: currentPosition.x,
                y: primaryHeight - (currentPosition.y + currentSize.height),
                width: currentSize.width,
                height: currentSize.height
            )
            targetScreen = NSScreen.screens.max(by: {
                let lhsArea = $0.frame.intersection(cocoaRect)
                let rhsArea = $1.frame.intersection(cocoaRect)
                return (lhsArea.width * lhsArea.height) < (rhsArea.width * rhsArea.height)
            })
        }
    } else {
        targetScreen = NSScreen.main ?? NSScreen.screens.first
    }

    guard let screen = targetScreen else { return }
    let visibleFrame = screen.visibleFrame
    let screenFrame = CGRect(
        x: visibleFrame.origin.x,
        y: primaryHeight - visibleFrame.maxY,
        width: visibleFrame.width,
        height: visibleFrame.height
    )
    
// 直接初始化为全屏状态
var newFrame = screenFrame

switch direction {
case "l":
    newFrame.size.width /= 2
case "r":
    newFrame.origin.x += screenFrame.width / 2
    newFrame.size.width /= 2
case "u":
    newFrame.size.height /= 2
case "d":
    newFrame.origin.y += screenFrame.height / 2
    newFrame.size.height /= 2
case "f":
    break // 保持全屏
default:
    return
}

// 最后如果需要赋值回变量
let newPosition = newFrame.origin
let newSize = newFrame.size
    
    // 设置窗口位置
    var positionValue = newPosition
    let positionRef = AXValueCreate(.cgPoint, &positionValue)!
    AXUIElementSetAttributeValue(window as! AXUIElement,
                                 kAXPositionAttribute as CFString,
                                 positionRef)
    
    // 设置窗口大小
    var sizeValue = newSize
    let sizeRef = AXValueCreate(.cgSize, &sizeValue)!
    AXUIElementSetAttributeValue(window as! AXUIElement,
                                 kAXSizeAttribute as CFString,
                                 sizeRef)
}


// MARK: - 搜索
func spotlightSearch(_ query: String) -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = [query]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    
    do { try task.run() } catch {
        return []
    }
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n").map(String.init)
}
// MARK: - 命令回调
func handleLauncherCommand(_ cmd: String) {
    let lower = cmd.lowercased()
    
    if lower == "l" || lower == "r"||lower == "f" || lower == "d" || lower == "u" {
        moveActiveWindow(direction: lower)
        return
    }
    // 其他情况 -> 通过登录 shell 执行(sioyek、code ~/... 等)
    LauncherRunner.run(cmd) { message in
        DispatchQueue.main.async {
            launcherToast.show(mode: .result, message: message)
        }
    }
}
func requestAXPermission() {
    let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    let trusted = AXIsProcessTrustedWithOptions(opts)
    print("AX trusted? \(trusted)")
}
// MARK: - App Entry
@main
struct SwiftlauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        requestAXPermission()
        print("OK!!requestAXPermission")
    }
    
    var body: some Scene {
        // 不显示任何窗口
        Settings {} // 空 Scene，用于 Settings 面板，如果不需要可以留空
    }
}



// MARK: - HotKey Manager
class HotKeyManager: ObservableObject {
    private var hotKey: HotKey?
    private var hotKeyQwen: HotKey?
    private var launcherHotKey: HotKey?
    private var volumeUpHotKey: HotKey?
    private var volumeDownHotKey: HotKey?
    private var alacrittyHotKey: HotKey?
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
//            self.handleHotKeyTranslate()
            let workspace = NSWorkspace.shared
                        if workspace.frontmostApplication?.bundleIdentifier == "net.sourceforge.skim-app.skim" {
                            // 当前是 Skim，执行自定义方法
                            self.handleHotKeyTranslate()
                        } else {
                            // 其他应用 → 模拟发送 ⌘T 给前台应用
                            self.sendCommandTToFrontmostApp()
                        }
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
        // ⌥ + Space 呼出输入框
        launcherHotKey = HotKey(key: .space, modifiers: [.option])
        launcherHotKey?.keyDownHandler = {
            // 输入模式，清空并弹出
            launcherToast.onSubmit = { text in
                // 交给你现有的命令处理函数
                handleLauncherCommand(text)
            }
            launcherToast.show(mode: .input, message: "")
        }
        alacrittyHotKey = HotKey(key: .return, modifiers: [.command])
        alacrittyHotKey?.keyDownHandler = {
            if launcherToast.handleCommandReturn() {
                return
            }
            print("Command + Enter triggered: Opening Alacritty")
            
            // 优先尝试通过路径直接打开，因为你已经确认了路径
            let appUrl = URL(fileURLWithPath: "/Applications/Alacritty.app")
            let config = NSWorkspace.OpenConfiguration()
            
            // 激活应用并将其带到前台
            config.activates = true
            
            NSWorkspace.shared.openApplication(at: appUrl, configuration: config) { (app, error) in
                if let error = error {
                    print("无法启动 Alacritty: \(error.localizedDescription)")
                    
                    // 备选方案：如果路径失败，尝试通过 Bundle ID 查找
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.alacritty") {
                        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
                    }
                }
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
    
    private func handleHotKeyTranslate() {
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

    func translateReceivedText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translate(text: text) { [weak self] result in
            self?.showTranslationToast(result)
        }
    }
    // MARK: - 翻译
    private func translate(text: String, from: String = "auto", to: String = "zh-CHS", completion: @escaping (String) -> Void) {
        guard !appKey.isEmpty && !appSecret.isEmpty else {
            var lines = ["缺Key! 终端运行:"]
            if appKey.isEmpty {
                lines.append("security add-generic-password -s YOUDAO_APP_KEY -a $USER -w <YOUR_KEY>")
            }
            if appSecret.isEmpty {
                lines.append("security add-generic-password -s YOUDAO_APP_SECRET -a $USER -w <YOUR_SECRET>")
            }
            completion(lines.joined(separator: "\n"))
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
            launcherToast.show(mode: .result, message: text)
        }
    }
    private func sendCommandTToFrontmostApp() {
        guard AXIsProcessTrusted(),
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: false) else {
            return
        }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.postToPid(frontmostApp.processIdentifier)
        keyUp.postToPid(frontmostApp.processIdentifier)
    }
}



class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    var hotKeyManager: HotKeyManager?
    private var ipcServer: SwiftlauncherIPCServer?
    
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
        LauncherEnvironment.shared.preload()
        ipcServer = SwiftlauncherIPCServer { [weak self] text in
            self?.hotKeyManager?.translateReceivedText(text)
        }
        ipcServer?.start()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 关键:应用启动时设置为 prohibited,防止抢焦点
        NSApp.setActivationPolicy(.prohibited)
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}
