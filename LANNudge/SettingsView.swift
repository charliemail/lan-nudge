import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var axTrusted = WindowShaker.isTrusted
    private static let peerRowHeight = NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .body)).rounded(.up)
    private static let peerSpacing: CGFloat = 6

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
                if !model.peers.isEmpty {
                    // Five rows tall at most; a busy office network lists many more Macs.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Self.peerSpacing) {
                            ForEach(model.peers) { Text(model.label(for: $0)).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: CGFloat(min(model.peers.count, 5)) * (Self.peerRowHeight + Self.peerSpacing) - Self.peerSpacing)
                }
                if let problem = model.networkProblem {
                    Text(problem).foregroundStyle(.orange)
                }
            }

            Section("接收") {
                Toggle("顯示對方附帶的訊息", isOn: $model.showMessages)
                Picker("附帶訊息的提醒", selection: $model.stickyNudges) {
                    Text("時間到自動消失").tag(false)
                    Text("點確認才消失").tag(true)
                }
                .pickerStyle(.segmented)
                if model.stickyNudges {
                    Toggle("點確認時通知對方已讀", isOn: $model.sendReadReceipts)
                    Stepper("排隊上限：\(model.queueLimit) 則", value: $model.queueLimit, in: AppModel.queueLimitRange)
                    Stepper("同一人最多：\(model.perSenderLimit) 則", value: $model.perSenderLimit, in: AppModel.perSenderRange)
                    if model.queueLimit != AppModel.defaultQueueLimit || model.perSenderLimit != AppModel.defaultPerSenderLimit {
                        Button("還原預設") {
                            model.queueLimit = AppModel.defaultQueueLimit
                            model.perSenderLimit = AppModel.defaultPerSenderLimit
                        }
                    }
                    Text("附帶訊息的提醒在動畫播完後會留在畫面上，點「確認」才清除，下一則接著出現；沒附訊息的照常時間到就消失。有 2 則以上未讀時，右上角顯示數量。螢幕鎖定或睡眠時收到的會先存著，解鎖後顯示。超過上限時，對方會看到「請稍後再試」。對方使用 0.4.0 以前的版本時，這段期間傳來的不會排隊。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    displayTime
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
                Text("開啟時，不論對方送哪種提醒，都只會由角色播放被電擊圖；對方已讀你的提醒時，角色播放已讀回條圖。拖曳角色可以移動位置；全螢幕時角色不會出現，改用一般提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.pet.error {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("紀錄與封鎖") {
                HStack {
                    Stepper("訊息紀錄：\(model.historyLimit) 筆", value: $model.historyLimit, in: AppModel.historyRange)
                    if model.historyLimit != AppModel.defaultHistoryLimit {
                        Button("還原預設") { model.historyLimit = AppModel.defaultHistoryLimit }
                    }
                }
                Text("只記附帶訊息的提醒，沒附訊息的不記。紀錄只存在記憶體，結束 App 就清除；暫停接收期間收到的也會記下來。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.blocked.isEmpty {
                    Text("沒有封鎖任何裝置。要封鎖時，從選單列「附近裝置」選對方 →「封鎖」。").foregroundStyle(.secondary)
                }
                ForEach(model.blocked.sorted { $0.value < $1.value }, id: \.key) { hint, name in
                    LabeledContent(name) {
                        Button("解除封鎖") { model.setBlocked(false, hint: hint, name: name) }
                    }
                }
                if !model.blocked.isEmpty {
                    Text("被封鎖的裝置傳來的提醒不會顯示，對方會看到「對方暫停接收」。")
                        .font(.caption).foregroundStyle(.secondary)
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
        // Taller than most screens with every section open: the form scrolls inside a window that
        // starts at a fixed height and can be dragged taller.
        .frame(width: 420)
        .frame(minHeight: 360, idealHeight: 620)
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

    @ViewBuilder private var displayTime: some View {
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

    private var displayMode: Binding<Bool> {
        Binding(get: { model.customDisplaySeconds != nil },
                set: { model.customDisplaySeconds = $0 ? (model.customDisplaySeconds ?? 5) : nil })
    }

    private func save() {
        model.setDisplayName(name)
        name = model.displayName
    }
}
