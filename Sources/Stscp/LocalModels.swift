// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AppKit
import UniformTypeIdentifiers

struct LocalFileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
    let kind: String
    let isParentNavigation: Bool

    var id: String {
        isParentNavigation ? "parent::\(url.path)" : url.path
    }
}

struct LocalOperationError: Identifiable {
    let id = UUID()
    let message: String
}

@MainActor
final class LocalPanelModel: ObservableObject {
    @Published var currentURL: URL
    @Published var items: [LocalFileItem] = []
    @Published var selection = Set<LocalFileItem.ID>()
    @Published var query = ""
    @Published var showHidden = false
    @Published var error: LocalOperationError?

    private let fileManager = FileManager.default

    init(url: URL) {
        currentURL = url
        reload()
    }

    var visibleItems: [LocalFileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return itemsWithParentNavigation }
        let filtered = itemsWithParentNavigation.filter {
            $0.isParentNavigation || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
        return filtered
    }

    var selectedItems: [LocalFileItem] {
        visibleItems.filter { selection.contains($0.id) && !$0.isParentNavigation }
    }

    private var parentItem: LocalFileItem? {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return nil }
        return LocalFileItem(
            url: parent,
            name: "...",
            isDirectory: true,
            size: nil,
            modifiedAt: nil,
            kind: "Parent folder",
            isParentNavigation: true
        )
    }

    private var itemsWithParentNavigation: [LocalFileItem] {
        guard let parentItem else { return items }
        return [parentItem] + items
    }

    @discardableResult
    func reload() -> Bool {
        do {
            let resourceKeys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .localizedTypeDescriptionKey,
                .isHiddenKey,
                .isSymbolicLinkKey
            ]

            let urls = try fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: showHidden ? [] : [.skipsHiddenFiles]
            )

            items = urls.compactMap { url in
                do {
                    let values = try url.resourceValues(forKeys: resourceKeys)
                    // Resource values describe the link itself; follow it so linked folders open as folders.
                    var isDirectory = values.isDirectory == true
                    if values.isSymbolicLink == true {
                        isDirectory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    }
                    return LocalFileItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: isDirectory,
                        size: values.fileSize.map(Int64.init),
                        modifiedAt: values.contentModificationDate,
                        kind: values.localizedTypeDescription ?? fallbackKind(for: url, isDirectory: isDirectory),
                        isParentNavigation: false
                    )
                } catch {
                    return nil
                }
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            selection = selection.filter { id in items.contains { $0.id == id } }
            return true
        } catch {
            self.error = LocalOperationError(message: "Cannot read \(currentURL.path): \(error.localizedDescription)")
            items = []
            selection = []
            return false
        }
    }

    func goHome() {
        navigate(to: fileManager.homeDirectoryForCurrentUser)
    }

    func goDesktop() {
        navigate(to: fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }

    func goDownloads() {
        navigate(to: fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    func goParent() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    func navigate(to url: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = LocalOperationError(message: "\(url.path) is not a folder.")
            return
        }

        let previousURL = currentURL
        currentURL = url.standardizedFileURL
        selection = []
        query = ""
        // An unreadable folder (e.g. privacy-protected) must not strand the panel on an empty listing.
        if !reload(), currentURL != previousURL {
            let error = self.error
            currentURL = previousURL
            reload()
            self.error = error ?? self.error
        }
    }

    func open(_ item: LocalFileItem) {
        if item.isParentNavigation {
            goParent()
        } else if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func createFolder(named name: String) {
        guard let folderName = sanitizedName(name, fallback: "New Folder") else { return }
        do {
            try fileManager.createDirectory(
                at: availableURL(for: currentURL.appendingPathComponent(folderName)),
                withIntermediateDirectories: false
            )
            reload()
        } catch {
            self.error = LocalOperationError(message: "Cannot create folder: \(error.localizedDescription)")
        }
    }

    func renameSelected(to newName: String) {
        guard let item = selectedItems.first else { return }
        guard let targetName = sanitizedName(newName, fallback: item.name) else { return }
        guard targetName != item.name else { return }
        let targetURL = item.url.deletingLastPathComponent().appendingPathComponent(targetName)
        // On case-insensitive volumes "a.txt" -> "A.txt" finds the item itself; don't rename it to "A 2.txt".
        let destination = isSameItem(item.url, targetURL) ? targetURL : availableURL(for: targetURL)
        do {
            try fileManager.moveItem(at: item.url, to: destination)
            reload()
        } catch {
            self.error = LocalOperationError(message: "Cannot rename \(item.name): \(error.localizedDescription)")
        }
    }

    func deleteSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        do {
            for item in targets {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
            }
        } catch {
            self.error = LocalOperationError(message: "Cannot move item to Trash: \(TransferQueue.describe(error))")
        }
        // Refresh even after a partial failure so already-trashed items disappear.
        let error = self.error
        reload()
        self.error = error ?? self.error
    }

    private func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = (try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let right = (try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier else {
            return false
        }
        return left.isEqual(right)
    }

    private func availableURL(for proposedURL: URL) -> URL {
        guard fileManager.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }

        let directory = proposedURL.deletingLastPathComponent()
        let base = proposedURL.deletingPathExtension().lastPathComponent
        let ext = proposedURL.pathExtension

        for index in 2...999 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(base) \(UUID().uuidString)").appendingPathExtension(ext)
    }

    private func sanitizedName(_ name: String, fallback: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != ".", trimmed != "..", !trimmed.contains("\0") else {
            error = LocalOperationError(message: "Enter a file or folder name other than . or .. and without null characters.")
            return nil
        }
        return trimmed.isEmpty ? fallback : trimmed.replacingOccurrences(of: "/", with: "-")
    }

    private func fallbackKind(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.localizedDescription ?? type.identifier
        }
        return "File"
    }
}
