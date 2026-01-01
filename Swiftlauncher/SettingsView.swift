import SwiftUI

struct SettingsView: View {
    // 对应你的三个变量名
    @State private var youdaoAppKey: String = ""
    @State private var youdaoAppSecret: String = ""
    @State private var dashscopeApiKey: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.headline)
            
            // --- 有道 App Key ---
            VStack(alignment: .leading) {
                Text("YOUDAO_APP_KEY")
                SecureField("输入 App Key", text: $youdaoAppKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            // --- 有道 App Secret ---
            VStack(alignment: .leading) {
                Text("YOUDAO_APP_SECRET")
                SecureField("输入 App Secret", text: $youdaoAppSecret)
                    .textFieldStyle(.roundedBorder)
            }
            
            // --- DashScope API Key ---
            VStack(alignment: .leading) {
                Text("DASHSCOPE_API_KEY")
                SecureField("输入 API Key", text: $dashscopeApiKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Spacer()
                Button("保存全部") {
                    // 调用你要求的 service 逻辑进行保存
                    saveToKeychain(service: "YOUDAO_APP_KEY", value: youdaoAppKey)
                    saveToKeychain(service: "YOUDAO_APP_SECRET", value: youdaoAppSecret)
                    saveToKeychain(service: "DASHSCOPE_API_KEY", value: dashscopeApiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            // 初始化读取，如果没有就显示空字符串
            youdaoAppKey = getKeychainValue(service: "YOUDAO_APP_KEY") ?? ""
            youdaoAppSecret = getKeychainValue(service: "YOUDAO_APP_SECRET") ?? ""
            dashscopeApiKey = getKeychainValue(service: "DASHSCOPE_API_KEY") ?? ""
        }
    }
    
    // --- 适配你读取逻辑的保存函数 ---
    func saveToKeychain(service: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // 关键：这里只用 kSecAttrService，不带 AccessGroup 就不会报权限错
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        
        // 先删后加，确保更新
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    // --- 你原本的读取逻辑 (去掉了 AccessGroup 干扰) ---
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
        }
        return nil
    }
}
