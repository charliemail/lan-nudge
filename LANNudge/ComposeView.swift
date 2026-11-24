import SwiftUI

/// "附帶訊息…": pick an effect and type a short message for the peer chosen in the menu.
struct ComposeView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var effect: Effect = .cartoonShock
    @State private var text = ""

    var body: some View {
        Form {
            if let peer = model.composeTarget {
                LabeledContent("傳給", value: model.label(for: peer))
                Picker("效果", selection: $effect) {
                    ForEach(Effect.allCases, id: \.self) { Text($0.title) }
                }
                TextField("訊息", text: $text, prompt: Text("例如：來開會了"))
                    .onSubmit { send(to: peer) }
                    .onChange(of: text) {
                        if text.count > NudgeMessage.maxLength { text = String(text.prefix(NudgeMessage.maxLength)) }
                    }
                HStack {
                    Text("\(text.count)/\(NudgeMessage.maxLength)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("送出") { send(to: peer) }.keyboardShortcut(.defaultAction)
                }
                Text("對方使用 0.4.0 以前的版本時，只會看到提醒，不會看到訊息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("請從選單列「附近裝置」選擇要傳給誰。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }

    private func send(to peer: Peer) {
        model.nudge(peer, with: effect, message: text)
        text = ""
        dismissWindow(id: "compose")
    }
}
