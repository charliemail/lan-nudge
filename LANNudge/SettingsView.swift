import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var name = ""

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
    }

    private func save() {
        model.setDisplayName(name)
        name = model.displayName
    }
}
