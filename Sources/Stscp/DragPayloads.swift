// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    /// Ad-hoc, app-private types: only used for drags between Stscp's own panels.
    /// `exportedAs` synthesizes a dynamic UTType at runtime even without an Info.plist
    /// declaration — plain `UTType(_:)` would return nil since nothing declares this identifier.
    static let stscpLocalPayload = UTType(exportedAs: "io.github.slaski20.stscp.local-drag-payload")
    static let stscpRemotePayload = UTType(exportedAs: "io.github.slaski20.stscp.remote-drag-payload")
}

/// Dragged from the local panel; dropping it on the remote panel triggers an upload.
struct LocalDragPayload: Codable, Transferable {
    struct Entry: Codable, Hashable {
        let path: String
        let isDirectory: Bool
    }

    let entries: [Entry]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stscpLocalPayload)
    }
}

/// Dragged from the remote panel; dropping it on the local panel triggers a download.
struct RemoteDragPayload: Codable, Transferable {
    struct Entry: Codable, Hashable {
        let path: String
        let isDirectory: Bool
        let size: Int64?
    }

    let entries: [Entry]
    /// `RemotePanelModel.connectionToken` of the panel the drag started in.
    var connectionToken: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stscpRemotePayload)
    }
}

/// Drags between Stscp's own panels. SwiftUI's `.draggable` exports `Transferable` data lazily and
/// asynchronously, so the synchronous `NSPasteboard` read in `DropTargetContainer` can come back empty
/// and the drop does nothing. These providers hand over ready-made JSON at once, visible only to this
/// process, and the payload is also kept in memory for the drop side to fall back on.
@MainActor
enum InternalDrag {
    private(set) static var local: LocalDragPayload?
    private(set) static var remote: RemoteDragPayload?

    static func provider(for payload: LocalDragPayload) -> NSItemProvider {
        local = payload
        return provider(payload, type: .stscpLocalPayload)
    }

    static func provider(for payload: RemoteDragPayload) -> NSItemProvider {
        remote = payload
        return provider(payload, type: .stscpRemotePayload)
    }

    /// The dragged payload of `type`: from the pasteboard, or the one this process started dragging.
    static func payload<T: Decodable>(_ type: T.Type, uti: UTType, from pasteboard: NSPasteboard) -> T? {
        let pasteboardType = NSPasteboard.PasteboardType(uti.identifier)
        guard pasteboard.types?.contains(pasteboardType) == true else { return nil }
        if let data = pasteboard.data(forType: pasteboardType),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        if T.self == LocalDragPayload.self { return local as? T }
        if T.self == RemoteDragPayload.self { return remote as? T }
        return nil
    }

    private static func provider<T: Encodable>(_ payload: T, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
