// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// SwiftUI's `.dropDestination`'s `action` closure never fires on this macOS build even though
/// `isTargeted`/the drag ghost work fine — a platform regression, not an app bug. This wraps SwiftUI
/// content in a real `NSView` that implements `NSDraggingDestination` directly, bypassing SwiftUI's
/// Transferable bridge entirely for the drop side. (The drag *source* side, `.draggable`, is unaffected
/// and stays as-is.)
struct DropTargetContainer<Content: View>: NSViewRepresentable {
    let acceptedTypes: [NSPasteboard.PasteboardType]
    let onEntered: () -> Void
    let onExited: () -> Void
    let onPerform: (NSPasteboard) -> Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.registerForDraggedTypes(acceptedTypes)
        view.onEntered = onEntered
        view.onExited = onExited
        view.onPerform = onPerform

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.hostingView = hosting
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onExited = onExited
        nsView.onPerform = onPerform
        nsView.hostingView?.rootView = content()
    }

    final class ContainerView: NSView {
        var onEntered: (() -> Void)?
        var onExited: (() -> Void)?
        var onPerform: ((NSPasteboard) -> Bool)?
        var hostingView: NSHostingView<Content>?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onEntered?()
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onExited?()
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let handled = onPerform?(sender.draggingPasteboard) ?? false
            onExited?()
            return handled
        }
    }
}
