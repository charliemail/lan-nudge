import AppKit
import SwiftUI

/// "附帶訊息…": pick an effect and type a short message for the peer chosen in the menu.
struct ComposeView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var effect: Effect = .cartoonShock
    @State private var text = ""

    /// Three lines of body text; longer messages scroll.
    private static let editorHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return (NSLayoutManager().defaultLineHeight(for: font) * 3).rounded(.up) + 8
    }()

    var body: some View {
        Form {
            if let peer = model.composeTarget {
                LabeledContent("傳給", value: model.label(for: peer))
                Picker("效果", selection: $effect) {
                    ForEach(Effect.allCases, id: \.self) { Text($0.title) }
                }
                // A multi-line editor rather than the form's TextField: that one is right-aligned,
                // and a right-aligned field doesn't draw trailing spaces until the next character.
                VStack(alignment: .leading, spacing: 6) {
                    Text("訊息")
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(height: Self.editorHeight)
                        .scrollIndicators(.visible)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("例如：來開會了").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                        .onChange(of: text) { old, new in
                            let edit = Self.edit(old: old, new: new)
                            if edit.text != new { text = edit.text }
                            if edit.send { send(to: peer) }
                        }
                }
                HStack {
                    Text("\(text.count)/\(NudgeMessage.maxLength)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("送出") { send(to: peer) }.keyboardShortcut(.defaultAction)
                }
                Text("按 Return 送出。對方使用 0.4.0 以前的版本時，只會看到提醒，不會看到訊息。")
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

    /// The editor takes Return as a line break; here a single typed Return means "send", as in the
    /// old one-line field. An input method commits its candidate on Return without inserting "\n",
    /// so Chinese input is unaffected. Pasted line breaks become spaces; the length stays capped.
    nonisolated static func edit(old: String, new: String) -> (text: String, send: Bool) {
        if new.contains(where: \.isNewline), new.filter({ !$0.isNewline }) == old, new.count == old.count + 1 {
            return (old, true)
        }
        let flat = String(new.map { $0.isNewline ? " " : $0 })
        return (String(flat.prefix(NudgeMessage.maxLength)), false)
    }

    private func send(to peer: Peer) {
        model.nudge(peer, with: effect, message: text)
        text = ""
        dismissWindow(id: "compose")
    }
}
