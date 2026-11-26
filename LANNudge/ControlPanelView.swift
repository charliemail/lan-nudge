import SwiftUI

/// Everything the menu bar menu offers, in a window: opened from the menu, by double-clicking the
/// desktop pet, or by opening the app again — for when the menu bar icon is crowded out.
struct ControlPanelView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.displayName.isEmpty ? "尚未設定名稱" : "本機：\(model.displayName)\(model.instance.map { "（實例 \($0)）" } ?? "")")
                    .font(.headline)
                Spacer()
                Toggle("暫停接收", isOn: $model.muted)
            }
            if let problem = model.identityError ?? model.networkProblem {
                Text("⚠️ \(problem)").foregroundStyle(.orange)
            }
            if let result = model.lastResult {
                Text(result).foregroundStyle(.secondary)
            }

            GroupBox("附近裝置") {
                if model.needsSetup {
                    Text("先到「設定」輸入顯示名稱，才會開始搜尋與接收。").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else if model.peers.isEmpty {
                    Text("沒有找到其他 Mac").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Five rows tall at most, like the settings list; a busy network lists many more Macs.
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.peers) { PeerRow(model: model, peer: $0) }
                        }
                    }
                    .frame(maxHeight: 5 * 30)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                if model.history.isEmpty {
                    Text("還沒有收到訊息").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.history) { Text($0.line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                HStack {
                    Text("最近收到的訊息（\(model.history.count)）")
                    Spacer()
                    if !model.history.isEmpty { Button("清除紀錄") { model.clearHistory() }.controlSize(.small) }
                }
            }

            HStack {
                Menu("預覽動畫") { PreviewItems(model: model) }.fixedSize()
                Button("設定…") { model.bringUp("settings") }
                Spacer()
                Text("版本 \(Bundle.main.versionText)").font(.caption).foregroundStyle(.secondary)
                Button("結束 LAN Nudge") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 460)
        .onExitCommand { dismissWindow(id: "panel") }
    }
}

private struct PeerRow: View {
    let model: AppModel
    let peer: Peer

    var body: some View {
        HStack(spacing: 6) {
            Text(model.label(for: peer) + (model.isBlocked(peer) ? "（已封鎖）" : ""))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Effect.allCases, id: \.self) { effect in
                Button { model.nudge(peer, with: effect) } label: {
                    EffectIcon(effect: effect).frame(width: 18)
                }
                .help(effect.title)
                .accessibilityLabel(effect.title)
            }
            Button("附帶訊息…") {
                model.composeTarget = peer
                model.bringUp("compose")
            }
            Menu {
                Button(model.isBlocked(peer) ? "解除封鎖" : "封鎖（不再收到他的提醒）") {
                    model.setBlocked(!model.isBlocked(peer), hint: peer.hint, name: model.label(for: peer))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多")
        }
        .frame(minHeight: 24)
    }
}
