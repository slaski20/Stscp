// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import AppKit

enum TerminalLauncherError: LocalizedError {
    case terminalNotFound

    var errorDescription: String? {
        switch self {
        case .terminalNotFound: return "Cannot find the Terminal application."
        }
    }
}

/// Opens macOS Terminal either in a local folder or running a command (an `ssh` session).
@MainActor
enum TerminalLauncher {
    private static let terminalBundleID = "com.apple.Terminal"

    /// Terminal opens a new window whose shell starts in the given folder.
    static func openLocal(at folder: URL) async throws {
        try await open(folder)
    }

    /// Terminal runs `.command` files, so the command goes into a one-shot script that deletes
    /// itself on start. The script holds no secrets: only the ssh arguments and socket path.
    static func run(executable: String, arguments: [String]) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stscp-terminal-\(UUID().uuidString).command")
        try Data(commandScript(executable: executable, arguments: arguments).utf8)
            .write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        do {
            try await open(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    nonisolated static func commandScript(executable: String, arguments: [String]) -> String {
        let command = ([executable] + arguments).map(SSHSession.shellEscape).joined(separator: " ")
        return "#!/bin/sh\nrm -f -- \"$0\"\nexec \(command)\n"
    }

    private static func open(_ url: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            throw TerminalLauncherError.terminalNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
    }
}
