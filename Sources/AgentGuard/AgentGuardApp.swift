import AppKit
import SwiftUI

@main
struct AgentGuardApp: App {
    @StateObject private var store = GuardStore()

    var body: some Scene {
        MenuBarExtra("Agent Guard", systemImage: "shield.lefthalf.filled") {
            GuardMenu(store: store)
        }
        Window("Agent Guard", id: "configuration") {
            ConfigurationView(store: store)
        }
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentMinSize)
    }
}

private struct GuardMenu: View {
    @ObservedObject var store: GuardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Agent Guard · 开发预览")
        Text("监控未接入 · 尚未保护任何应用")
        Divider()
        Button("应用与文件规则…") {
            openWindow(id: "configuration")
            NSApp.activate(ignoringOtherApps: true)
        }
        Text("\(store.configuration.applications.count) 个应用 · \(store.configuration.rules.count) 条文件规则")
        Divider()
        Button("退出 Agent Guard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
