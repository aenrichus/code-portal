import SwiftUI

/// Global settings window (Cmd+,).
struct SettingsView: View {
    @AppStorage("globalClaudeArgs") private var globalClaudeArgs: String = ""
    @AppStorage("appearance") private var appearance: String = "auto"
    @State private var draft: String = ""
    @State private var hasChanges: Bool = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.segmented)
                Text("Auto follows your macOS system appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude CLI Arguments") {
                TextField("Global flags (applied to all repos)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, _ in
                        hasChanges = draft != globalClaudeArgs
                    }
                Text("e.g., --model opus --verbose")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Applied to all repos. Takes effect on next session start or restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save") {
                    globalClaudeArgs = draft
                    hasChanges = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .padding()
        .onAppear {
            draft = globalClaudeArgs
        }
    }
}
