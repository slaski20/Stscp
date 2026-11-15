// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

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
