// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum RemotePath {
    static func join(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    static func resolve(_ path: String, relativeTo base: String) -> String {
        let absolute = path.hasPrefix("/") ? path : join(base, path)
        var components: [Substring] = []
        for component in absolute.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        if path == "/" || path.isEmpty { return "/" }
        var trimmed = path
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let index = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[trimmed.startIndex..<index])
        return parent.isEmpty ? "/" : parent
    }
}

struct RemoteFileItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modifiedRaw: String
    let permissions: String
    let isParentNavigation: Bool

    var id: String { isParentNavigation ? "parent::\(path)" : path }
}

struct RemoteOperationError: Identifiable {
    let id = UUID()
    let message: String
}

enum RemoteConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class RemotePanelModel: ObservableObject {
    @Published var connectionState: RemoteConnectionState = .disconnected
    @Published var profile: SiteProfile?
    @Published var currentPath = "."
    @Published var items: [RemoteFileItem] = []
    @Published var selection = Set<RemoteFileItem.ID>()
    @Published var query = ""
    @Published var showHidden = false
    @Published var error: RemoteOperationError?
    @Published var isBusy = false

    private(set) var session: SSHSession
    private let makeSession: () -> SSHSession
    private var connectionID = UUID()
    private var reloadID = UUID()

    init(makeSession: @escaping () -> SSHSession = { SSHSession() }) {
        self.makeSession = makeSession
        self.session = makeSession()
    }

    var isConnected: Bool { connectionState == .connected }

    /// Changes on every connect/disconnect; drag payloads carry it so a drop from another
    /// window (or an older connection) cannot download paths from the wrong server.
    var connectionToken: UUID { connectionID }

    var visibleItems: [RemoteFileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return itemsWithParentNavigation }
        let filtered = items.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        guard let parentItem else { return filtered }
        return [parentItem] + filtered
    }

    var selectedItems: [RemoteFileItem] {
        visibleItems.filter { selection.contains($0.id) && !$0.isParentNavigation }
    }

    private var parentItem: RemoteFileItem? {
        guard isConnected, currentPath != "/" else { return nil }
        return RemoteFileItem(
            path: RemotePath.parent(of: currentPath),
            name: "...",
            isDirectory: true,
            isSymlink: false,
            size: nil,
            modifiedRaw: "",
            permissions: "",
            isParentNavigation: true
        )
    }

    private var itemsWithParentNavigation: [RemoteFileItem] {
        guard let parentItem else { return items }
        return [parentItem] + items
    }

    /// On success a password is remembered for this app session only; on failure it is
    /// forgotten so a wrong password is not offered again.
    func connect(to profile: SiteProfile, password: String? = nil) async {
        let requestID = UUID()
        connectionID = requestID
        reloadID = UUID()
        let previousSession = session
        let newSession = makeSession()
        session = newSession
        connectionState = .connecting
        self.profile = profile
        items = []
        selection = []
        currentPath = "."
        isBusy = false
        error = nil
        await previousSession.disconnect()
        guard connectionID == requestID else { return }

        do {
            try await newSession.connect(profile, password: password)
            if profile.authMethod == .password, let password {
                SessionPasswords.shared.set(password, for: profile.id)
            }
            guard connectionID == requestID else {
                await newSession.disconnect()
                return
            }
            let home = try await newSession.remoteHomeDirectory()
            guard connectionID == requestID else { return }
            let requested = profile.remotePath.trimmingCharacters(in: .whitespaces)
            let startPath = RemotePath.resolve(requested.isEmpty ? "." : requested, relativeTo: home)
            connectionState = .connected
            await navigate(to: startPath)
        } catch {
            guard connectionID == requestID else { return }
            if profile.authMethod == .password, !(await newSession.isConnected) {
                SessionPasswords.shared.remove(for: profile.id)
            }
            await newSession.disconnect()
            guard connectionID == requestID else { return }
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        connectionID = UUID()
        reloadID = UUID()
        let previousSession = session
        session = makeSession()
        connectionState = .disconnected
        profile = nil
        items = []
        selection = []
        currentPath = "."
        isBusy = false
        error = nil
        await previousSession.disconnect()
    }

    /// Returns `false` only when this listing failed; superseded listings count as success.
    @discardableResult
    func reload() async -> Bool {
        guard isConnected else { return false }
        let requestID = UUID()
        reloadID = requestID
        let path = currentPath
        isBusy = true
        defer { if reloadID == requestID { isBusy = false } }
        do {
            let entries = try await session.listDirectory(path)
            guard reloadID == requestID, isConnected else { return true }
            items = entries
                .filter { showHidden || !$0.name.hasPrefix(".") }
                .map { entry in
                    RemoteFileItem(
                        path: RemotePath.join(path, entry.name),
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        isSymlink: entry.isSymlink,
                        size: entry.isDirectory ? nil : entry.size,
                        modifiedRaw: entry.modifiedRaw,
                        permissions: entry.permissions,
                        isParentNavigation: false
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            selection = selection.filter { id in items.contains { $0.id == id } }
            return true
        } catch {
            guard reloadID == requestID, isConnected else { return true }
            self.error = RemoteOperationError(message: error.localizedDescription)
            items = []
            selection = []
            return false
        }
    }

    func navigate(to path: String) async {
        guard isConnected else { return }
        let previousPath = currentPath
        let target = RemotePath.resolve(path, relativeTo: currentPath)
        currentPath = target
        selection = []
        query = ""
        // A mistyped or unreadable path must not leave the panel stranded on an empty listing.
        let connection = connectionID
        if await !reload(), connectionID == connection, currentPath == target, previousPath.hasPrefix("/"),
           previousPath != target {
            currentPath = previousPath
            let error = self.error
            await reload()
            self.error = error ?? self.error
        }
    }

    func goParent() async {
        guard isConnected, currentPath != "/" else { return }
        await navigate(to: RemotePath.parent(of: currentPath))
    }

    func open(_ item: RemoteFileItem) async {
        if item.isParentNavigation || item.isDirectory {
            await navigate(to: item.path)
        } else if item.isSymlink, isConnected {
            // `ls -l` reports links as `l`, so ask the server whether the link points at a folder.
            let session = self.session
            guard (try? await session.itemKinds([item.path]))?.first == .directory, session === self.session else { return }
            await navigate(to: item.path)
        }
    }

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, validEntryName(trimmed) else { return }
        do {
            try await session.makeDirectory(RemotePath.join(currentPath, trimmed))
            await reload()
        } catch {
            self.error = RemoteOperationError(message: error.localizedDescription)
        }
    }

    func renameSelected(to newName: String) async {
        guard let item = selectedItems.first else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, validEntryName(trimmed), trimmed != item.name else { return }
        let newPath = RemotePath.join(RemotePath.parent(of: item.path), trimmed)
        do {
            try await session.rename(from: item.path, to: newPath)
            await reload()
        } catch {
            self.error = RemoteOperationError(message: error.localizedDescription)
        }
    }

    func deleteSelected() async {
        let targets = selectedItems
        guard isConnected, !targets.isEmpty else { return }
        let session = self.session
        do {
            for item in targets {
                try await session.remove(item.path, isDirectory: item.isDirectory)
            }
        } catch {
            self.error = RemoteOperationError(message: error.localizedDescription)
        }
        // Refresh even after a partial failure so already-deleted items disappear.
        guard session === self.session else { return }
        let error = self.error
        await reload()
        self.error = error ?? self.error
    }

    private func validEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            error = RemoteOperationError(message: "Enter a single file or folder name without /; . and .. are not valid names.")
            return false
        }
        return true
    }
}
