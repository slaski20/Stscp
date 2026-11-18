// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalPanelView: View {
    @ObservedObject var model: LocalPanelModel
    let isActive: Bool
    let onActivate: () -> Void
    /// Items to transfer to the remote panel; `true` moves instead of copying.
    let onTransfer: ([LocalFileItem], Bool) -> Void
    let onDropDownload: (RemoteDragPayload) -> Bool

    @State private var isDropTargeted = false
    @State private var selectionAnchor: LocalFileItem.ID?
    @State private var pathFieldText = ""

    private let sizeFormatter = ByteCountFormatter()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let sizeColumnWidth: CGFloat = 90
    private let modifiedColumnWidth: CGFloat = 160
    private let kindColumnWidth: CGFloat = 140

    var body: some View {
        DropTargetContainer(
            acceptedTypes: [NSPasteboard.PasteboardType(UTType.stscpRemotePayload.identifier)],
            onEntered: { isDropTargeted = true },
            onExited: { isDropTargeted = false },
            onPerform: { pasteboard in handleDrop(pasteboard) }
        ) {
            VStack(spacing: 0) {
                header
                Divider()
                columnHeader
                Divider()
                fileList
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
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        model.navigate(to: URL(fileURLWithPath: expanded))
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let payload = InternalDrag.payload(RemoteDragPayload.self, uti: .stscpRemotePayload, from: pasteboard),
              !payload.entries.isEmpty else { return false }
        return onDropDownload(payload)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                Text("Local")
                    .font(.headline)

                TextField("Path", text: $pathFieldText, onCommit: navigateToTypedPath)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onAppear { pathFieldText = model.currentURL.path }
                    .onChange(of: model.currentURL) { newValue in pathFieldText = newValue.path }

                Spacer()

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

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
        .padding(10)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: sizeColumnWidth, alignment: .trailing)
            Text("Modified").frame(width: modifiedColumnWidth, alignment: .leading)
            Text("Kind").frame(width: kindColumnWidth, alignment: .leading)
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
    private func row(for item: LocalFileItem) -> some View {
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

            Text(dateText(for: item))
                .foregroundStyle(.secondary)
                .frame(width: modifiedColumnWidth, alignment: .leading)

            Text(item.kind)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: kindColumnWidth, alignment: .leading)
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
            Button("Copy to Remote") { transferSelection(move: false) }
            Button("Move to Remote") { transferSelection(move: true) }
            Button("Reveal in Finder") { reveal(item) }
            Button("Copy Path") { copyPath(item) }
            Divider()
            Button("Go to Parent") { model.goParent() }
        }

        if item.isParentNavigation {
            content
        } else {
            content.onDrag { InternalDrag.provider(for: dragPayload(for: item)) }
        }
    }

    private func selectOnClick(_ item: LocalFileItem) {
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

    private func open(_ item: LocalFileItem) {
        onActivate()
        model.open(item)
    }

    private func transferSelection(move: Bool) {
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        onTransfer(items, move)
    }

    private func reveal(_ item: LocalFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func copyPath(_ item: LocalFileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    /// Dragging a row that's part of a multi-selection carries the whole selection (files and folders alike); otherwise just that row.
    private func dragPayload(for item: LocalFileItem) -> LocalDragPayload {
        let selected = model.selectedItems
        let source = (selected.count > 1 && selected.contains(where: { $0.id == item.id })) ? selected : [item]
        return LocalDragPayload(entries: source.map { .init(path: $0.url.path, isDirectory: $0.isDirectory) })
    }

    private func iconName(for item: LocalFileItem) -> String {
        if item.isParentNavigation { return "arrowshape.turn.up.left.fill" }
        return item.isDirectory ? "folder.fill" : "doc"
    }

    private func sizeText(for item: LocalFileItem) -> String {
        if item.isDirectory || item.isParentNavigation { return "" }
        guard let size = item.size else { return "" }
        return sizeFormatter.string(fromByteCount: size)
    }

    private func dateText(for item: LocalFileItem) -> String {
        if item.isParentNavigation { return "" }
        guard let date = item.modifiedAt else { return "" }
        return dateFormatter.string(from: date)
    }
}
