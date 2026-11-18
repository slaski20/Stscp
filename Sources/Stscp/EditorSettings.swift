// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The application used to view files (F3). Only the app's path is stored, in user defaults.
@MainActor
final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()
    static let defaultsKey = "preferredEditorPath"
    private static let fallbackBundleID = "com.apple.TextEdit"

    private let defaults: UserDefaults

    /// `nil` means the built-in default (TextEdit).
    @Published var editorPath: String? {
        didSet { defaults.set(editorPath, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.editorPath = defaults.string(forKey: Self.defaultsKey)
    }

    /// The chosen editor if it is still installed, otherwise TextEdit.
    var editorURL: URL? {
        if let editorPath, FileManager.default.fileExists(atPath: editorPath) {
            return URL(fileURLWithPath: editorPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.fallbackBundleID)
    }

    var isUsingDefault: Bool { editorPath == nil }

    var displayName: String {
        guard let url = editorURL else { return "TextEdit" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func chooseEditor() {
        let panel = NSOpenPanel()
        panel.title = "Choose Editor"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editorPath = url.path
        }
    }

    func resetToDefault() {
        editorPath = nil
    }

    func open(_ file: URL) async throws {
        guard let editor = editorURL else { throw EditorError.editorNotFound }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: configuration)
    }
}

enum EditorError: LocalizedError {
    case editorNotFound

    var errorDescription: String? {
        "Cannot find the editor application. Choose one in Settings."
    }
}

struct EditorSettingsSection: View {
    @ObservedObject var settings: EditorSettings

    var body: some View {
        Section {
            HStack(spacing: 10) {
                if let url = settings.editorURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.displayName)
                        .font(.headline)
                    Text(settings.isUsingDefault ? "Default editor" : (settings.editorPath ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            HStack {
                Button("Choose…") { settings.chooseEditor() }
                Button("Use TextEdit") { settings.resetToDefault() }
                    .disabled(settings.isUsingDefault)
            }
        } header: {
            Text("Editor for viewing files (F3)")
        } footer: {
            Text("Remote files are downloaded to a temporary read-only copy; changes are not uploaded back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
