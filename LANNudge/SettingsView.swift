import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var name = ""
    @State private var axTrusted = WindowShaker.isTrusted

    var body: some View {
        Form {
            Section("本機") {
                HStack {
                    TextField("顯示名稱", text: $name, prompt: Text("例如：小明的 MacBook"))
                        .onSubmit(save)
                    Button("儲存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == model.displayName)
                }
                if let error = model.identityError {
                    Text(error).foregroundStyle(.red)
                }
                LabeledContent("震動真實視窗") {
                    if axTrusted {
                        Text("已允許").foregroundStyle(.secondary)
                    } else {
                        Button("開啟輔助使用權限…") { WindowShaker.requestPermission() }
                    }
                }
                if !axTrusted {
                    Text("未允許時，「視窗震動」只會晃動提醒小窗。重新建置或更新 App 後，請在「系統設定 → 隱私權與安全性 → 輔助使用」移除 LAN Nudge 再重新加入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("附近裝置") {
                if model.needsSetup {
                    Text("先設定顯示名稱，才會開始搜尋與接收。").foregroundStyle(.secondary)
                } else if model.peers.isEmpty {
                    Text("找不到其他 Mac。請確認兩端都已開啟 LAN Nudge；訪客 Wi-Fi、AP 隔離或防火牆會讓裝置互相看不到。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.peers) { Text(model.label(for: $0)) }
                if let problem = model.networkProblem {
                    Text(problem).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            name = model.displayName
            NSApp.activate()
        }
        .task {
            // The system sends no notification when the permission changes; poll while open.
            while !Task.isCancelled {
                axTrusted = WindowShaker.isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func save() {
        model.setDisplayName(name)
        name = model.displayName
    }
}
