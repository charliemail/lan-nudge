import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
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

            Section("接收") {
                Toggle("顯示對方附帶的訊息", isOn: $model.showMessages)
                Picker("提醒顯示時間", selection: displayMode) {
                    Text("自動").tag(false)
                    Text("自訂").tag(true)
                }
                .pickerStyle(.segmented)
                if let seconds = model.customDisplaySeconds {
                    HStack {
                        Slider(value: Binding(get: { Double(seconds) }, set: { model.customDisplaySeconds = Int($0.rounded()) }),
                               in: Double(AppModel.displayRange.lowerBound)...Double(AppModel.displayRange.upperBound), step: 1)
                        Text("\(seconds) 秒").monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button("還原預設") { model.customDisplaySeconds = nil }
                    }
                    Text("每則提醒都顯示這麼久。顯示期間別人再戳你會排隊（最多 5 則），設越長等越久。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("沒附訊息：提醒小窗 2 秒，桌面寵物播一輪動畫。附訊息：3 秒加上每 10 字 1 秒，最長 8 秒。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("桌面寵物") {
                Toggle("顯示桌面寵物", isOn: Bindable(model.pet).enabled)
                ForEach(DesktopPet.Pose.allCases, id: \.self) { pose in
                    LabeledContent(pose.title) {
                        HStack {
                            Text(model.pet.customPoses.contains(pose) ? "自訂" : "預設").foregroundStyle(.secondary)
                            if model.pet.customPoses.contains(pose) {
                                Button("還原預設") { model.pet.restoreDefault(pose) }
                            }
                            Button("選擇 GIF…") { model.pet.choose(pose) }
                        }
                    }
                }
                Text("開啟時，不論對方送哪種提醒，都只會由角色播放被電擊圖。拖曳角色可以移動位置；全螢幕時角色不會出現，改用一般提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.pet.error {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("授權條款") {
                    Button("開啟…") {
                        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
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

    private var displayMode: Binding<Bool> {
        Binding(get: { model.customDisplaySeconds != nil },
                set: { model.customDisplaySeconds = $0 ? (model.customDisplaySeconds ?? 5) : nil })
    }

    private func save() {
        model.setDisplayName(name)
        name = model.displayName
    }
}
