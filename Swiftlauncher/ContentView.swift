//
//  ContentView.swift
//  Swiftlauncher
//
//  Created by liuming on 2025/11/5.
//

import SwiftUI

// MARK: - ContentView
struct ContentView: View {
    var body: some View {
        VStack {
            Text("Swiftlauncher running...")
                .font(.title)
                .padding()
            Text("Press ⌘ + T to translate clipboard")
                .foregroundColor(.gray)
        }
    }
}

#Preview {
    ContentView()
}
