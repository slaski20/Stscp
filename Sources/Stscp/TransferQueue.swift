// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum TransferDirection {
    case upload
    case download
}

enum TransferState: Equatable {
    case queued
    case running(progress: Double?)
    case completed
    case failed(String)
}

@MainActor
final class TransferTask: Identifiable, ObservableObject {
    let id = UUID()
    let direction: TransferDirection
    let name: String
    /// A move removes the source after the copy has been verified.
    let isMove: Bool
    @Published var state: TransferState = .queued

    func updateProgress(_ progress: Double) {
        guard case .running = state else { return }
        state = .running(progress: min(1, max(0, progress)))
    }

    init(direction: TransferDirection, name: String, isMove: Bool = false) {
        self.direction = direction
        self.name = name
        self.isMove = isMove
    }
}

/// Runs uploads/downloads one at a time via `SSHSession`, polling file size on the side
/// (local stat for downloads, remote `stat` for uploads) to approximate progress, since the
/// underlying `scp`/`ssh` processes don't expose a machine-readable progress stream when piped.
@MainActor
final class TransferQueue: ObservableObject {
    @Published var tasks: [TransferTask] = []

    private var pendingWork: [() async -> Void] = []
    private var isProcessing = false

    /// With `moveSource`, the local item goes to the Trash once the remote copy has the same size.
    func enqueueUpload(session: SSHSession, localURL: URL, remotePath: String, isDirectory: Bool,
                       moveSource: Bool = false, completion: @escaping () -> Void) {
        let totalBytes = isDirectory ? nil : localFileSize(localURL)
        let task = TransferTask(direction: .upload, name: localURL.lastPathComponent, isMove: moveSource)
        tasks.append(task)

        enqueue { [task] in
            task.state = .running(progress: totalBytes != nil ? 0 : nil)

            let pollTask = totalBytes.map { total in
                Task { [weak task] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 700_000_000) }
                        catch { return }
                        guard let task, total > 0 else { continue }
                        let current = await session.fileSize(at: remotePath) ?? 0
                        guard !Task.isCancelled else { return }
                        task.updateProgress(Double(current) / Double(total))
                    }
                }
            }

            do {
                try await session.upload(localPath: localURL.path, remotePath: remotePath, isDirectory: isDirectory)
            } catch {
                pollTask?.cancel()
                task.state = .failed(error.localizedDescription)
                return
            }
            pollTask?.cancel()
            if moveSource {
                let verified: Bool
                if let totalBytes {
                    verified = await session.fileSize(at: remotePath) == totalBytes
                } else {
                    verified = true
                }
                await self.removeSource(of: task, verified: verified) {
                    try FileManager.default.trashItem(at: localURL, resultingItemURL: nil)
                }
            }
            self.finish(task)
            completion()
        }
    }

    /// With `moveSource`, the remote item is deleted once the local copy has the same size.
    func enqueueDownload(session: SSHSession, remotePath: String, localURL: URL, remoteSize: Int64?, isDirectory: Bool,
                         moveSource: Bool = false, completion: @escaping () -> Void) {
        let totalBytes = isDirectory ? nil : remoteSize
        let task = TransferTask(direction: .download, name: localURL.lastPathComponent, isMove: moveSource)
        tasks.append(task)

        enqueue { [task] in
            task.state = .running(progress: totalBytes != nil ? 0 : nil)

            let pollTask = totalBytes.map { total in
                Task { [weak task] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 500_000_000) }
                        catch { return }
                        guard let task, total > 0 else { continue }
                        let current = self.localFileSize(localURL) ?? 0
                        guard !Task.isCancelled else { return }
                        task.updateProgress(Double(current) / Double(total))
                    }
                }
            }

            do {
                try await session.download(remotePath: remotePath, localPath: localURL.path, isDirectory: isDirectory)
            } catch {
                pollTask?.cancel()
                task.state = .failed(error.localizedDescription)
                return
            }
            pollTask?.cancel()
            if moveSource {
                let verified: Bool
                if isDirectory {
                    var isFolder: ObjCBool = false
                    verified = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isFolder) && isFolder.boolValue
                } else {
                    var expected = totalBytes
                    if expected == nil { expected = await session.fileSize(at: remotePath) }
                    verified = expected != nil && self.localFileSize(localURL) == expected
                }
                await self.removeSource(of: task, verified: verified) {
                    try await session.remove(remotePath, isDirectory: isDirectory)
                }
            }
            self.finish(task)
            completion()
        }
    }

    /// Never removes a source whose copy could not be confirmed.
    private func removeSource(of task: TransferTask, verified: Bool, remove: () async throws -> Void) async {
        guard verified else {
            task.state = .failed("Copied, but the copy could not be verified. The source was kept.")
            return
        }
        do {
            try await remove()
        } catch {
            task.state = .failed("Copied, but the source could not be removed: \(Self.describe(error))")
        }
    }

    /// macOS privacy protection (TCC) reports blocked folder access as a plain permission error;
    /// say where to grant it, since nothing in the app can fix that by itself.
    static func describe(_ error: Error) -> String {
        if isPrivacyDenial(error) {
            return "Permission denied. macOS privacy protection is likely blocking Stscp: allow it in System Settings → "
                + "Privacy & Security → Files and Folders (or Full Disk Access), then try again."
        }
        return error.localizedDescription
    }

    static func isPrivacyDenial(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
                 (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                 (NSPOSIXErrorDomain, Int(EPERM)),
                 (NSOSStatusErrorDomain, -5000): // afpAccessDenied, what trashItem reports
                return true
            default:
                current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        }
        return false
    }

    private func finish(_ task: TransferTask) {
        if case .failed = task.state { return }
        task.state = .completed
    }

    /// Removes done and failed transfers; queued and running ones stay. An empty queue hides the panel.
    func clearFinished() {
        tasks.removeAll {
            switch $0.state {
            case .completed, .failed: return true
            case .queued, .running: return false
            }
        }
    }

    private func localFileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        pendingWork.append(work)
        processNext()
    }

    private func processNext() {
        guard !isProcessing, !pendingWork.isEmpty else { return }
        isProcessing = true
        let work = pendingWork.removeFirst()
        Task {
            await work()
            isProcessing = false
            processNext()
        }
    }
}
