// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// How transfers run; stored in user defaults.
@MainActor
final class TransferSettings: ObservableObject {
    static let shared = TransferSettings()
    nonisolated static let defaultParallelTransfers = 3
    static let parallelRange = 1...4
    static let parallelKey = "parallelTransfers"
    static let compressKey = "compressFolderTransfers"

    private let defaults: UserDefaults

    @Published var parallelTransfers: Int {
        didSet {
            let clamped = Self.clamp(parallelTransfers)
            if clamped != parallelTransfers { parallelTransfers = clamped; return }
            defaults.set(parallelTransfers, forKey: Self.parallelKey)
        }
    }

    /// gzip for folder (`tar`) transfers: helps on slow links with compressible data, costs CPU on fast ones.
    @Published var compressFolderTransfers: Bool {
        didSet { defaults.set(compressFolderTransfers, forKey: Self.compressKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        parallelTransfers = Self.clamp(defaults.object(forKey: Self.parallelKey) as? Int ?? Self.defaultParallelTransfers)
        compressFolderTransfers = defaults.bool(forKey: Self.compressKey)
    }

    private static func clamp(_ value: Int) -> Int {
        min(parallelRange.upperBound, max(parallelRange.lowerBound, value))
    }
}

struct TransferSettingsSection: View {
    @ObservedObject var settings: TransferSettings

    var body: some View {
        Section {
            Stepper(value: $settings.parallelTransfers, in: TransferSettings.parallelRange) {
                Text("Parallel transfers: \(settings.parallelTransfers)")
            }
            Toggle("Compress folder transfers (gzip)", isOn: $settings.compressFolderTransfers)
        } header: {
            Text("Transfers")
        } footer: {
            Text("Folders are sent as a single tar stream, which is much faster for many small files. "
                + "Compression helps on slow connections with text-like data; on fast networks or with "
                + "already compressed files (photos, video, archives) it slows transfers down.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            EditorSettingsSection(settings: EditorSettings.shared)
            TransferSettingsSection(settings: TransferSettings.shared)
        }
        .padding(20)
        .frame(width: 480)
    }
}
