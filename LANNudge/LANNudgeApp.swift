import SwiftUI

@main
struct LANNudgeApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // macOS turns a held letter key into the accent picker instead of repeating it. Messages here
        // are short chat text, so a held key repeats. A registered default: an explicit system-wide
        // choice (defaults write -g ApplePressAndHoldEnabled) still wins.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(model: model, delegate: delegate)
        }

        Window("LAN Nudge", id: "panel") {
            ControlPanelView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

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

    var body: some View {
        Text(model.displayName.isEmpty ? "尚未設定名稱" : "本機：\(model.displayName)\(model.instance.map { "（實例 \($0)）" } ?? "")")
        if let problem = model.identityError ?? model.networkProblem {
            Text("⚠️ \(problem)")
        }

        Section("附近裝置") {
            if model.peers.isEmpty { Text("沒有找到其他 Mac") }
            ForEach(model.peers) { peer in
                Menu(model.label(for: peer) + (model.isBlocked(peer) ? "（已封鎖）" : "")) {
                    ForEach(Effect.allCases, id: \.self) { effect in
                        Button(effect.title) { model.nudge(peer, with: effect) }
                    }
                    Divider()
                    Button("附帶訊息…") {
                        model.composeTarget = peer
                        model.bringUp("compose")
                    }
                    Divider()
                    Button(model.isBlocked(peer) ? "解除封鎖" : "封鎖（不再收到他的提醒）") {
                        model.setBlocked(!model.isBlocked(peer), hint: peer.hint, name: model.label(for: peer))
                    }
                }
            }
            Button(model.scanning ? "掃描 VPN 中…" : "掃描 VPN 上的裝置") { model.scanVPN() }
                .disabled(model.scanning || model.needsSetup)
        }

        if let result = model.lastResult { Text(result) }

        Menu("最近收到的訊息（\(model.history.count)）") {
            if model.history.isEmpty { Text("還沒有收到訊息") }
            ForEach(model.history) { item in
                Text(item.line)
            }
            if !model.history.isEmpty {
                Divider()
                Button("清除紀錄") { model.clearHistory() }
            }
        }

        Divider()
        Toggle("暫停接收", isOn: $model.muted)
        Menu("預覽動畫") { PreviewItems(model: model) }
        Button("控制面板…") { model.bringUp("panel") }
        Button("設定…") { model.bringUp("settings") }
        Divider()
        Button("結束 LAN Nudge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

}

/// The menu bar icon. It hands SwiftUI's window opener to the model and the relaunch hook to the
/// app delegate, so AppKit code can open windows too.
private struct MenuBarIcon: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "bolt.fill")
            .onAppear {
                model.openWindow = openWindow
                delegate.onReopen = { [weak model] in model?.bringUp("panel") }
            }
    }
}

/// Opening the app again (Spotlight, Finder) while it runs shows the control panel: the way back
/// when the menu bar icon is crowded out and the desktop pet is off.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen?()
        return false
    }
}

/// Shared by the menu bar menu and the control panel.
struct PreviewItems: View {
    let model: AppModel

    var body: some View {
        ForEach(Effect.allCases, id: \.self) { effect in
            Button(effect.title) { model.present(effect, from: "預覽") }
        }
        Divider()
        // Follows the receiving settings, so with 點確認才消失 it waits for 確認 like a real one.
        Button("附帶訊息") { model.present(.cartoonShock, from: "預覽", message: "這是附帶訊息的預覽，對方傳來的文字會顯示在這裡。") }
        Button("已讀回條") { model.showRead(from: "預覽") }
    }
}

extension Bundle {
    /// "0.5.0 (6)"
    var versionText: String {
        "\(infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
    }
}
