// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemotePanelView: View {
    @ObservedObject var model: RemotePanelModel
    let isActive: Bool
    let onActivate: () -> Void
    /// Items to transfer to the local panel; `true` moves instead of copying.
    let onTransfer: ([RemoteFileItem], Bool) -> Void
    let onOpenSiteManager: () -> Void
    let onDropUpload: ([LocalDragPayload.Entry]) -> Void

    @State private var isDropTargeted = false
    @State private var selectionAnchor: RemoteFileItem.ID?
    @State private var pathFieldText = ""

    private let sizeFormatter = ByteCountFormatter()

    private let sizeColumnWidth: CGFloat = 90
    private let modifiedColumnWidth: CGFloat = 130
    private let permissionsColumnWidth: CGFloat = 110

    var body: some View {
        DropTargetContainer(
            acceptedTypes: [NSPasteboard.PasteboardType(UTType.stscpLocalPayload.identifier), .fileURL],
            onEntered: { isDropTargeted = true },
            onExited: { isDropTargeted = false },
            onPerform: { pasteboard in handleDrop(pasteboard) }
        ) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
            .overlay(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .border(isDropTargeted ? Color.accentColor : Color.clear, width: 2)
            .contentShape(Rectangle())
            .onTapGesture { onActivate() }
            .onChange(of: model.selection) { _ in onActivate() }
        }
    }

    private func navigateToTypedPath() {
        let trimmed = pathFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.isConnected else { return }
        Task { await model.navigate(to: trimmed) }
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard model.isConnected else { return false }

        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.stscpLocalPayload.identifier)),
           let payload = try? JSONDecoder().decode(LocalDragPayload.self, from: data),
           !payload.entries.isEmpty {
            onDropUpload(payload.entries)
            return true
        }

        // Fallback for drags originating outside the app (e.g. directly from Finder).
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let entries = urls.map { url -> LocalDragPayload.Entry in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return .init(path: url.path, isDirectory: isDirectory.boolValue)
        }
        onDropUpload(entries)
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch model.connectionState {
        case .disconnected:
            placeholder(
                systemImage: "network.slash",
                title: "Not connected",
                message: "Open the Site Manager to connect to an SFTP server.",
                actionTitle: "Site Manager...",
                action: onOpenSiteManager
            )
        case .connecting:
            placeholder(systemImage: "network", title: "Connecting...", message: model.profile?.subtitle ?? "", actionTitle: nil, action: nil)
        case .failed(let message):
            placeholder(
                systemImage: "exclamationmark.triangle",
                title: "Connection failed",
                message: message,
                actionTitle: "Site Manager...",
                action: onOpenSiteManager
            )
        case .connected:
            VStack(spacing: 0) {
                columnHeader
                Divider()
                fileList
            }
        }
    }

    private func placeholder(systemImage: String, title: String, message: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.isConnected ? "network" : "network.slash")
                    .foregroundStyle(model.isConnected ? Color.green : (isActive ? Color.accentColor : Color.secondary))

                Text("Remote")
                    .font(.headline)

                if model.isConnected {
                    TextField("Path", text: $pathFieldText, onCommit: navigateToTypedPath)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .onAppear { pathFieldText = model.currentPath }
                        .onChange(of: model.currentPath) { newValue in pathFieldText = newValue }
                } else if let profile = model.profile {
                    Text(profile.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if model.isConnected {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }

            if model.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter files", text: $model.query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: sizeColumnWidth, alignment: .trailing)
            Text("Modified").frame(width: modifiedColumnWidth, alignment: .leading)
            Text("Permissions").frame(width: permissionsColumnWidth, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleItems) { item in
                    row(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: RemoteFileItem) -> some View {
        let isSelected = model.selection.contains(item.id)

        let content = HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: item))
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText(for: item))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: sizeColumnWidth, alignment: .trailing)

            Text(item.modifiedRaw)
                .foregroundStyle(.secondary)
                .frame(width: modifiedColumnWidth, alignment: .leading)

            Text(item.permissions)
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: permissionsColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { open(item) }
                .exclusively(before: TapGesture(count: 1).onEnded { selectOnClick(item) })
        )
        .contextMenu {
            Button("Open") { open(item) }
            Button("Copy to Local") { transferSelection(move: false) }
            Button("Move to Local") { transferSelection(move: true) }
            Button("Copy Path") { copyPath(item) }
            Divider()
            Button("Go to Parent") { Task { await model.goParent() } }
        }

        if item.isParentNavigation {
            content
        } else {
            content.draggable(dragPayload(for: item))
        }
    }

    private func selectOnClick(_ item: RemoteFileItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let anchorIndex = model.visibleItems.firstIndex(where: { $0.id == anchor }),
                  let currentIndex = model.visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = anchorIndex < currentIndex ? anchorIndex...currentIndex : currentIndex...anchorIndex
            model.selection = Set(model.visibleItems[range].map { $0.id })
        } else {
            model.selection = [item.id]
            selectionAnchor = item.id
        }
        onActivate()
    }

    private func open(_ item: RemoteFileItem) {
        onActivate()
        Task { await model.open(item) }
    }

    private func transferSelection(move: Bool) {
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        onTransfer(items, move)
    }

    private func copyPath(_ item: RemoteFileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    /// Dragging a row that's part of a multi-selection carries the whole selection; otherwise just that row.
    private func dragPayload(for item: RemoteFileItem) -> RemoteDragPayload {
        let selected = model.selectedItems
        let source = (selected.count > 1 && selected.contains(where: { $0.id == item.id })) ? selected : [item]
        return RemoteDragPayload(
            entries: source.map { .init(path: $0.path, isDirectory: $0.isDirectory, size: $0.size) },
            connectionToken: model.connectionToken
        )
    }

    private func iconName(for item: RemoteFileItem) -> String {
        if item.isParentNavigation { return "arrowshape.turn.up.left.fill" }
        if item.isSymlink { return "arrow.triangle.branch" }
        return item.isDirectory ? "folder.fill" : "doc"
    }

    private func sizeText(for item: RemoteFileItem) -> String {
        guard let size = item.size, !item.isDirectory else { return "" }
        return sizeFormatter.string(fromByteCount: size)
    }
}
