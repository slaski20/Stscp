// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

struct CommanderView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @StateObject private var localPanel = LocalPanelModel(url: FileManager.default.homeDirectoryForCurrentUser)
    @StateObject private var remotePanel = RemotePanelModel()
    @StateObject private var siteStore = SiteStore()
    @StateObject private var transferQueue = TransferQueue()

    @State private var activeSide: PanelSide = .local
    @State private var pendingDialog: PendingDialog?
    @State private var dialogText = ""
    @State private var showDeleteConfirmation = false
    @State private var showSiteManager = false
    @State private var overwritePlan: TransferPlan?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HStack(spacing: 0) {
                LocalPanelView(
                    model: localPanel,
                    isActive: activeSide == .local,
                    onActivate: { activeSide = .local },
                    onTransfer: { items, move in uploadItems(items, move: move) },
                    onDropDownload: { payload in
                        // Remote paths are only meaningful for the connection they were dragged from.
                        guard remotePanel.isConnected, payload.connectionToken == remotePanel.connectionToken else { return false }
                        downloadRemotePaths(payload.entries)
                        return true
                    }
                )

                Divider()

                RemotePanelView(
                    model: remotePanel,
                    isActive: activeSide == .remote,
                    onActivate: { activeSide = .remote },
                    onTransfer: { items, move in downloadItems(items, move: move) },
                    onOpenSiteManager: { showSiteManager = true },
                    onDropUpload: { entries in uploadLocalPaths(entries) }
                )
            }

            if !transferQueue.tasks.isEmpty {
                TransferQueueView(queue: transferQueue)
            }

            Divider()
            functionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Closing the window must not leave the SSH ControlMaster running in the background.
        .onDisappear { Task { await remotePanel.disconnect() } }
        .onReceive(NotificationCenter.default.publisher(for: .focusCommanderPanel)) { notification in
            guard controlActiveState == .key,
                  let side = notification.object as? PanelSide else { return }
            activeSide = side
        }
        .onReceive(NotificationCenter.default.publisher(for: .commanderAction)) { notification in
            guard controlActiveState == .key,
                  let action = notification.object as? CommanderAction else { return }
            perform(action)
        }
        .alert(item: localErrorBinding) { error in
            Alert(title: Text("Local file operation failed"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert(item: remoteErrorBinding) { error in
            Alert(title: Text("Remote operation failed"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert("Delete selected items?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteActiveSelection()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            overwritePlan.map(overwriteTitle) ?? "",
            isPresented: Binding(get: { overwritePlan != nil }, set: { if !$0 { overwritePlan = nil } }),
            presenting: overwritePlan
        ) { plan in
            Button("Overwrite", role: .destructive) { start(plan, includingExisting: true) }
            if plan.conflicts.count < plan.items.count {
                Button("Skip Existing") { start(plan, includingExisting: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(overwriteMessage(plan))
        }
        .sheet(item: $pendingDialog) { dialog in
            TextInputDialog(
                title: dialog.title,
                message: dialog.message,
                text: $dialogText,
                confirmTitle: dialog.confirmTitle,
                onCancel: { pendingDialog = nil },
                onConfirm: { confirm(dialog) }
            )
        }
        .sheet(isPresented: $showSiteManager) {
            SiteManagerView(
                store: siteStore,
                onConnect: { profile, password in
                    showSiteManager = false
                    activeSide = .remote
                    Task { await remotePanel.connect(to: profile, password: password) }
                },
                onClose: { showSiteManager = false }
            )
        }
    }

    private var deleteConfirmationMessage: String {
        switch activeSide {
        case .local:
            let count = localPanel.selectedItems.count
            if count == 1, let item = localPanel.selectedItems.first {
                return "Move \(item.name) to Trash?"
            }
            return "Move \(count) selected items to Trash?"
        case .remote:
            let count = remotePanel.selectedItems.count
            if count == 1, let item = remotePanel.selectedItems.first {
                return "Permanently delete \(item.name) from the server?"
            }
            return "Permanently delete \(count) selected items from the server?"
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { localPanel.goParent() } label: { Label("Up", systemImage: "arrow.up") }
                .help("Go to parent folder (local)")
            Button { localPanel.goHome() } label: { Label("Home", systemImage: "house") }
            Button { localPanel.goDesktop() } label: { Label("Desktop", systemImage: "desktopcomputer") }
            Button { localPanel.goDownloads() } label: { Label("Downloads", systemImage: "arrow.down.circle") }

            Divider().frame(height: 24)

            Button { showSiteManager = true } label: { Label("Sites", systemImage: "server.rack") }
                .help("Site Manager")

            if remotePanel.isConnected {
                Button {
                    Task { await remotePanel.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }

            Divider().frame(height: 24)

            Toggle(isOn: showHiddenBinding) {
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Show hidden files in active panel")

            Spacer()

            Text(activeSide == .local ? "Active: local panel" : "Active: remote panel")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var functionBar: some View {
        HStack(spacing: 8) {
            // Direction follows the active panel, so one Copy/Move pair covers upload and download.
            commandButton(activeSide == .local ? "F5 Copy →" : "F5 ← Copy", "doc.on.doc", action: .copy)
            commandButton(activeSide == .local ? "F6 Move →" : "F6 ← Move", "arrow.right.doc.on.clipboard", action: .move)
            commandButton("New Folder", "folder.badge.plus", action: .newFolder)
            commandButton("Rename", "pencil", action: .rename)
            commandButton("Delete", "trash", action: .delete)
            commandButton("Refresh", "arrow.clockwise", action: .refresh)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func commandButton(_ title: String, _ systemImage: String, action: CommanderAction) -> some View {
        Button {
            perform(action)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private func perform(_ action: CommanderAction) {
        switch action {
        case .copy, .move:
            let move = action == .move
            switch activeSide {
            case .local: uploadItems(localPanel.selectedItems, move: move)
            case .remote: downloadItems(remotePanel.selectedItems, move: move)
            }
        case .rename:
            renameActiveSelection()
        case .delete:
            let hasSelection = activeSide == .local ? !localPanel.selectedItems.isEmpty : !remotePanel.selectedItems.isEmpty
            guard hasSelection else { return }
            showDeleteConfirmation = true
        case .newFolder:
            newFolderInActivePanel()
        case .refresh:
            refreshActivePanel()
        case .siteManager:
            showSiteManager = true
        case .disconnect:
            Task { await remotePanel.disconnect() }
        }
    }

    private func refreshActivePanel() {
        switch activeSide {
        case .local: localPanel.reload()
        case .remote: Task { await remotePanel.reload() }
        }
    }

    private func renameActiveSelection() {
        switch activeSide {
        case .local:
            guard let item = localPanel.selectedItems.first else { return }
            dialogText = item.name
            pendingDialog = PendingDialog(kind: .renameLocal, title: "Rename", message: "Enter a new name for \(item.name).", confirmTitle: "Rename")
        case .remote:
            guard let item = remotePanel.selectedItems.first else { return }
            dialogText = item.name
            pendingDialog = PendingDialog(kind: .renameRemote, title: "Rename", message: "Enter a new name for \(item.name).", confirmTitle: "Rename")
        }
    }

    private func newFolderInActivePanel() {
        switch activeSide {
        case .local:
            dialogText = "New Folder"
            pendingDialog = PendingDialog(kind: .newFolderLocal, title: "New Folder", message: "Create a folder in \(localPanel.currentURL.path).", confirmTitle: "Create")
        case .remote:
            guard remotePanel.isConnected else { return }
            dialogText = "New Folder"
            pendingDialog = PendingDialog(kind: .newFolderRemote, title: "New Folder", message: "Create a folder in \(remotePanel.currentPath).", confirmTitle: "Create")
        }
    }

    private func deleteActiveSelection() {
        switch activeSide {
        case .local: localPanel.deleteSelected()
        case .remote: Task { await remotePanel.deleteSelected() }
        }
    }

    private func confirm(_ dialog: PendingDialog) {
        switch dialog.kind {
        case .renameLocal: localPanel.renameSelected(to: dialogText)
        case .newFolderLocal: localPanel.createFolder(named: dialogText)
        case .renameRemote: Task { await remotePanel.renameSelected(to: dialogText) }
        case .newFolderRemote: Task { await remotePanel.createFolder(named: dialogText) }
        }
        pendingDialog = nil
    }

    private func uploadItems(_ items: [LocalFileItem], move: Bool) {
        uploadLocalPaths(items.map { .init(path: $0.url.path, isDirectory: $0.isDirectory) }, move: move)
    }

    private func downloadItems(_ items: [RemoteFileItem], move: Bool) {
        downloadRemotePaths(items.map { .init(path: $0.path, isDirectory: $0.isDirectory, size: $0.size) }, move: move)
    }

    /// Shared by Copy/Move from the local panel and dropping local rows onto the remote panel.
    private func uploadLocalPaths(_ entries: [LocalDragPayload.Entry], move: Bool = false) {
        guard remotePanel.isConnected, !entries.isEmpty else { return }
        let session = remotePanel.session
        let base = remotePanel.currentPath
        let candidates = entries.map { entry -> (entry: LocalDragPayload.Entry, url: URL, remotePath: String) in
            let url = URL(fileURLWithPath: entry.path)
            return (entry, url, RemotePath.join(base, url.lastPathComponent))
        }
        Task {
            let kinds: [RemoteItemKind]
            do {
                kinds = try await session.itemKinds(candidates.map(\.remotePath))
            } catch {
                guard session === remotePanel.session else { return }
                remotePanel.error = RemoteOperationError(message: error.localizedDescription)
                return
            }
            guard session === remotePanel.session else { return }
            var items: [PlannedTransfer] = []
            var mismatched: [String] = []
            for (candidate, kind) in zip(candidates, kinds) {
                let existing = kind == .missing ? nil : kind == .directory
                // A file and a folder with the same name cannot replace each other; scp would nest one inside the other.
                if let existing, existing != candidate.entry.isDirectory {
                    mismatched.append(candidate.url.lastPathComponent)
                    continue
                }
                items.append(PlannedTransfer(
                    name: candidate.url.lastPathComponent,
                    localURL: candidate.url,
                    remotePath: candidate.remotePath,
                    isDirectory: candidate.entry.isDirectory,
                    remoteSize: nil,
                    exists: existing != nil
                ))
            }
            propose(TransferPlan(direction: .upload, move: move, session: session, items: items, mismatched: mismatched))
        }
    }

    /// Shared by Copy/Move from the remote panel and dropping remote rows onto the local panel.
    private func downloadRemotePaths(_ entries: [RemoteDragPayload.Entry], move: Bool = false) {
        guard remotePanel.isConnected, !entries.isEmpty else { return }
        var items: [PlannedTransfer] = []
        var mismatched: [String] = []
        for entry in entries {
            let name = (entry.path as NSString).lastPathComponent
            let localURL = localPanel.currentURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue != entry.isDirectory {
                mismatched.append(name)
                continue
            }
            items.append(PlannedTransfer(
                name: name,
                localURL: localURL,
                remotePath: entry.path,
                isDirectory: entry.isDirectory,
                remoteSize: entry.size,
                exists: exists
            ))
        }
        propose(TransferPlan(direction: .download, move: move, session: remotePanel.session, items: items, mismatched: mismatched))
    }

    /// Starts conflict-free plans immediately; otherwise asks before anything is replaced.
    private func propose(_ plan: TransferPlan) {
        if plan.conflicts.isEmpty {
            if !plan.mismatched.isEmpty { reportSkipped(plan) }
            start(plan, includingExisting: false)
        } else {
            overwritePlan = plan
        }
    }

    private func start(_ plan: TransferPlan, includingExisting: Bool) {
        overwritePlan = nil
        // The user may have reconnected elsewhere while the question was open.
        guard plan.session === remotePanel.session, remotePanel.isConnected else {
            if !plan.items.isEmpty {
                remotePanel.error = RemoteOperationError(message: "The connection changed before the transfer started. Nothing was transferred.")
            }
            return
        }
        for item in plan.items where includingExisting || !item.exists {
            switch plan.direction {
            case .upload:
                transferQueue.enqueueUpload(
                    session: plan.session,
                    localURL: item.localURL,
                    remotePath: item.remotePath,
                    isDirectory: item.isDirectory,
                    moveSource: plan.move
                ) {
                    Task { await remotePanel.reload() }
                    if plan.move { localPanel.reload() }
                }
            case .download:
                transferQueue.enqueueDownload(
                    session: plan.session,
                    remotePath: item.remotePath,
                    localURL: item.localURL,
                    remoteSize: item.remoteSize,
                    isDirectory: item.isDirectory,
                    moveSource: plan.move
                ) {
                    localPanel.reload()
                    if plan.move { Task { await remotePanel.reload() } }
                }
            }
        }
    }

    private func reportSkipped(_ plan: TransferPlan) {
        let message = "Skipped \(Self.nameList(plan.mismatched)): the destination already has a "
            + "file where a folder would go, or a folder where a file would go."
        switch plan.direction {
        case .upload: remotePanel.error = RemoteOperationError(message: message)
        case .download: localPanel.error = LocalOperationError(message: message)
        }
    }

    private func overwriteTitle(_ plan: TransferPlan) -> String {
        let conflicts = plan.conflicts
        if conflicts.count == 1, let item = conflicts.first {
            return item.isDirectory ? "Folder \"\(item.name)\" already exists" : "\"\(item.name)\" already exists"
        }
        return "\(conflicts.count) items already exist"
    }

    private func overwriteMessage(_ plan: TransferPlan) -> String {
        let conflicts = plan.conflicts
        let place = plan.direction == .upload ? "on the server in \(remotePanel.currentPath)" : "in \(localPanel.currentURL.path)"
        var lines = ["Already \(place): \(Self.nameList(conflicts.map(\.name)))."]
        lines.append("Overwriting replaces existing files and cannot be undone.")
        if conflicts.contains(where: \.isDirectory) {
            lines.append("Existing folders are merged: files with the same names inside them are replaced.")
        }
        let fresh = plan.items.count - conflicts.count
        if fresh > 0 {
            lines.append("Skip Existing transfers only the \(fresh) new item\(fresh == 1 ? "" : "s").")
        }
        if !plan.mismatched.isEmpty {
            lines.append("Always skipped (file/folder type differs): \(Self.nameList(plan.mismatched)).")
        }
        if plan.move {
            lines.append("Moved sources are removed only after their copy is verified; skipped items stay where they are.")
        }
        return lines.joined(separator: "\n\n")
    }

    private static func nameList(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        return names.count > 5 ? "\(shown) and \(names.count - 5) more" : shown
    }
}

/// One upload or download, with whether its destination already exists.
private struct PlannedTransfer {
    let name: String
    let localURL: URL
    let remotePath: String
    let isDirectory: Bool
    let remoteSize: Int64?
    let exists: Bool
}

/// A batch of transfers waiting for overwrite confirmation, bound to the session it was checked against.
private struct TransferPlan: Identifiable {
    let id = UUID()
    let direction: TransferDirection
    let move: Bool
    let session: SSHSession
    let items: [PlannedTransfer]
    let mismatched: [String]

    var conflicts: [PlannedTransfer] { items.filter(\.exists) }
}

private enum DialogKind {
    case renameLocal
    case renameRemote
    case newFolderLocal
    case newFolderRemote
}

private struct PendingDialog: Identifiable {
    let id = UUID()
    let kind: DialogKind
    let title: String
    let message: String
    let confirmTitle: String
}

private extension CommanderView {
    var showHiddenBinding: Binding<Bool> {
        Binding(
            get: { activeSide == .local ? localPanel.showHidden : remotePanel.showHidden },
            set: { newValue in
                switch activeSide {
                case .local:
                    localPanel.showHidden = newValue
                    localPanel.reload()
                case .remote:
                    remotePanel.showHidden = newValue
                    Task { await remotePanel.reload() }
                }
            }
        )
    }

    var localErrorBinding: Binding<LocalOperationError?> {
        Binding(get: { localPanel.error }, set: { localPanel.error = $0 })
    }

    var remoteErrorBinding: Binding<RemoteOperationError?> {
        Binding(get: { remotePanel.error }, set: { remotePanel.error = $0 })
    }
}
