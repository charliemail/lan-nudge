import SwiftUI

@main
struct LANNudgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("LAN Nudge", systemImage: "bolt.fill") {
            MenuContent(model: model)
        }

        Window("LAN Nudge 設定", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.needsSetup ? .presented : .suppressed)

        Window("附帶訊息", id: "compose") {
            ComposeView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.displayName.isEmpty ? "尚未設定名稱" : "本機：\(model.displayName)\(model.instance.map { "（實例 \($0)）" } ?? "")")
        if let problem = model.identityError ?? model.networkProblem {
            Text("⚠️ \(problem)")
        }

        Section("附近裝置") {
            if model.peers.isEmpty { Text("沒有找到其他 Mac") }
            ForEach(model.peers) { peer in
                Menu(model.label(for: peer)) {
                    ForEach(Effect.allCases, id: \.self) { effect in
                        Button(effect.title) { model.nudge(peer, with: effect) }
                    }
                    Divider()
                    Button("附帶訊息…") {
                        model.composeTarget = peer
                        bringUp("compose")
                    }
                }
            }
        }

        if let result = model.lastResult { Text(result) }

        Divider()
        Toggle("暫停接收", isOn: $model.muted)
        Menu("預覽動畫") {
            ForEach(Effect.allCases, id: \.self) { effect in
                Button(effect.title) { model.present(effect, from: "預覽") }
            }
        }
        Button("設定…") { bringUp("settings") }
        Divider()
        Button("結束 LAN Nudge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A menu bar app isn't the active app when its menu is used, and NSApp.activate() is only a
    /// request macOS may turn down, so the window would open (or stay) behind the current app's
    /// windows. Ordering it front directly works either way.
    private func bringUp(_ id: String) {
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.activate()
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) else { return }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}
