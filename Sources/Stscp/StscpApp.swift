// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// Running via `swift run` / the raw debug binary (no `.app` bundle, no `Info.plist`) makes macOS
/// treat the process as background-only by default: no Dock icon, no Cmd+Tab entry, no app menu
/// bar. Forcing `.regular` + activating brings it to the front like a normal app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct StscpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CommanderView()
                .frame(minWidth: 1080, minHeight: 660)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Commander") {
                Button("Focus local panel") {
                    NotificationCenter.default.post(name: .focusCommanderPanel, object: PanelSide.local)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Focus remote panel") {
                    NotificationCenter.default.post(name: .focusCommanderPanel, object: PanelSide.remote)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Button("Site Manager...") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.siteManager)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Disconnect") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.disconnect)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                // Like a two-panel commander: F5 copies and F6 moves from the active panel to the other one.
                Button("Copy to Other Panel") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.copy)
                }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: [])

                Button("Move to Other Panel") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.move)
                }
                .keyboardShortcut(Self.functionKey(NSF6FunctionKey), modifiers: [])

                Button("Rename") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.rename)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("New Folder") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.newFolder)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Delete") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.delete)
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button("Refresh") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.refresh)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                // Local panel: Terminal in the current folder; remote panel: ssh into the current remote folder.
                Button("Open Terminal") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.openTerminal)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("View in Editor") {
                    NotificationCenter.default.post(name: .commanderAction, object: CommanderAction.viewFile)
                }
                .keyboardShortcut(Self.functionKey(NSF3FunctionKey), modifiers: [])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension StscpApp {
    static func functionKey(_ code: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(code))!))
    }
}

enum PanelSide: String, Hashable {
    case local
    case remote
}

enum CommanderAction {
    /// Transfers the active panel's selection to the other panel (upload or download).
    case copy
    /// Like `copy`, then removes the source once the copy is verified.
    case move
    case rename
    case delete
    case newFolder
    case refresh
    /// Opens Terminal in the active panel's folder: locally, or over SSH for the remote panel.
    case openTerminal
    /// Opens the selected file in the editor chosen in Settings (remote files via a temporary copy).
    case viewFile
    case siteManager
    case disconnect
}

extension Notification.Name {
    static let focusCommanderPanel = Notification.Name("focusCommanderPanel")
    static let commanderAction = Notification.Name("commanderAction")
}
