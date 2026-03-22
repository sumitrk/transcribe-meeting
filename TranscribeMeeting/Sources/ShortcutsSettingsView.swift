import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            // MARK: Push-to-Talk
            Section {
                LabeledContent("Key") {
                    PTTRecorderView(
                        keyCode:   $store.pttKeyCode,
                        modifiers: $store.pttModifiers
                    )
                }
            } header: {
                Text("Push-to-Talk")
            } footer: {
                Text("Hold \(store.pttKeyLabel) to record. Release to transcribe and paste.")
            }

            // MARK: Toggle Record
            Section {
                LabeledContent("Key") {
                    KeyRecorderView(
                        keyCode:   $store.toggleKeyCode,
                        modifiers: $store.toggleModifiers
                    )
                }

                LabeledContent("Save transcripts to") {
                    HStack(spacing: 6) {
                        Text(store.transcriptFolder.abbreviatedPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            pickFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Toggle Record  (saves transcript as markdown)")
            } footer: {
                Text("Press \(store.toggleKeyLabel) to start, press again to stop and save.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where transcripts will be saved."
        if panel.runModal() == .OK, let url = panel.url {
            store.transcriptFolderPath = url.path
        }
    }
}

// MARK: - KeyBadge

struct KeyBadge: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
    }
}

// MARK: - URL helper

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
