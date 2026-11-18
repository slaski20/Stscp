// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

enum SSHError: LocalizedError {
    case connectionFailed(String)
    case commandFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "Connection failed: \(message)"
        case .commandFailed(let message): return message
        case .notConnected: return "Not connected to a remote site."
        }
    }
}

struct RemoteEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modifiedRaw: String
    let permissions: String
}

enum RemoteItemKind: Sendable, Equatable {
    case missing
    case file
    case directory
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Serialize pipe reads and drain the bytes available at child exit. Do not wait for EOF:
/// a background SSH master can inherit the pipe after its launching process exits.
private final class ProcessOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func drain() {
        lock.lock()
        defer { lock.unlock() }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One side of a two-process pipeline (`producer | consumer`).
struct PipelineStage: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

/// Resumes once both pipeline processes have exited, whatever order they finish in.
private final class PipelineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult?] = [nil, nil]
    private var continuation: CheckedContinuation<(ProcessResult, ProcessResult), Error>?

    init(_ continuation: CheckedContinuation<(ProcessResult, ProcessResult), Error>) {
        self.continuation = continuation
    }

    func finish(_ index: Int, _ result: ProcessResult) {
        lock.lock()
        results[index] = result
        guard let first = results[0], let second = results[1], let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: (first, second))
    }
}

enum ProcessRunner {
    /// Runs `producer | consumer` without a shell, so no argument is ever re-parsed, and reports
    /// both exit statuses (a shell pipeline would hide the producer's failure).
    static func runPipeline(_ producer: PipelineStage, into consumer: PipelineStage,
                            environment: [String: String] = [:]) async throws -> (ProcessResult, ProcessResult) {
        try await withCheckedThrowingContinuation { continuation in
            let collector = PipelineCollector(continuation)
            let first = Process()
            let second = Process()
            for (process, stage) in [(first, producer), (second, consumer)] {
                process.executableURL = URL(fileURLWithPath: stage.executable)
                process.arguments = stage.arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }
            }
            let link = Pipe()
            let firstErr = Pipe()
            let secondOut = Pipe()
            let secondErr = Pipe()
            first.standardInput = FileHandle.nullDevice
            first.standardOutput = link
            first.standardError = firstErr
            second.standardInput = link
            second.standardOutput = secondOut
            second.standardError = secondErr

            let outputs = [ProcessOutput(firstErr.fileHandleForReading),
                           ProcessOutput(secondOut.fileHandleForReading),
                           ProcessOutput(secondErr.fileHandleForReading)]
            let handles = [firstErr, secondOut, secondErr].map(\.fileHandleForReading)
            for (handle, output) in zip(handles, outputs) {
                handle.readabilityHandler = { _ in output.drain() }
            }
            first.terminationHandler = { finished in
                firstErr.fileHandleForReading.readabilityHandler = nil
                outputs[0].drain()
                collector.finish(0, ProcessResult(exitCode: finished.terminationStatus, stdout: "", stderr: outputs[0].text))
            }
            second.terminationHandler = { finished in
                secondOut.fileHandleForReading.readabilityHandler = nil
                secondErr.fileHandleForReading.readabilityHandler = nil
                outputs[1].drain()
                outputs[2].drain()
                collector.finish(1, ProcessResult(exitCode: finished.terminationStatus,
                                                  stdout: outputs[1].text, stderr: outputs[2].text))
            }

            do {
                try second.run()
            } catch {
                handles.forEach { $0.readabilityHandler = nil }
                continuation.resume(throwing: error)
                return
            }
            do {
                try first.run()
            } catch {
                // The consumer is already waiting for input: end it instead of leaving it blocked.
                firstErr.fileHandleForReading.readabilityHandler = nil
                try? link.fileHandleForWriting.close()
                second.terminate()
                collector.finish(0, ProcessResult(exitCode: 127, stdout: "", stderr: error.localizedDescription))
            }
        }
    }

    static func run(executable: String, arguments: [String], environment: [String: String] = [:]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let stdout = ProcessOutput(stdoutPipe.fileHandleForReading)
            let stderr = ProcessOutput(stderrPipe.fileHandleForReading)
            stdoutPipe.fileHandleForReading.readabilityHandler = { _ in stdout.drain() }
            stderrPipe.fileHandleForReading.readabilityHandler = { _ in stderr.drain() }

            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdout.drain()
                stderr.drain()
                continuation.resume(returning: ProcessResult(
                    exitCode: finished.terminationStatus,
                    stdout: stdout.text,
                    stderr: stderr.text
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Talks SFTP by shelling out to the system OpenSSH client (ssh/scp), reusing a single
/// authenticated connection via ControlMaster so every subsequent call avoids re-authenticating.
actor SSHSession {
    private(set) var profile: SiteProfile?
    private var controlPath: String?
    private var connectionAttempt: UUID?
    /// Held only in memory for this connection; never written to disk or passed as an argument.
    private var password: String?
    private let run: @Sendable (String, [String], [String: String]) async throws -> ProcessResult
    private let runPipeline: @Sendable (PipelineStage, PipelineStage, [String: String]) async throws -> (ProcessResult, ProcessResult)

    init() {
        self.run = { try await ProcessRunner.run(executable: $0, arguments: $1, environment: $2) }
        self.runPipeline = { try await ProcessRunner.runPipeline($0, into: $1, environment: $2) }
    }

    /// Test seam that ignores the process environment. Pipelines run their two stages
    /// through `run` one after the other, so tests see (and can answer) both commands.
    init(run: @escaping @Sendable (String, [String]) async throws -> ProcessResult) {
        self.init(runWithEnvironment: { executable, arguments, _ in try await run(executable, arguments) })
    }

    /// Test seam that also receives the extra environment (used for password authentication).
    init(runWithEnvironment: @escaping @Sendable (String, [String], [String: String]) async throws -> ProcessResult) {
        self.run = runWithEnvironment
        self.runPipeline = { producer, consumer, environment in
            (try await runWithEnvironment(producer.executable, producer.arguments, environment),
             try await runWithEnvironment(consumer.executable, consumer.arguments, environment))
        }
    }

    var isConnected: Bool { profile != nil }

    /// `password` is used only when the profile selects password authentication.
    func connect(_ profile: SiteProfile, password: String? = nil) async throws {
        guard profile.isValid else {
            throw SSHError.connectionFailed("Enter a valid host, username, and port (1–65535).")
        }
        let password = profile.authMethod == .password ? password : nil
        if profile.authMethod == .password, password?.isEmpty ?? true {
            throw SSHError.connectionFailed("Enter the password for \(profile.subtitle).")
        }
        let attempt = UUID()
        connectionAttempt = attempt
        // A fresh, short socket path prevents edited sites and separate windows from
        // reusing another connection's credentials or terminating each other's master.
        let path = "/tmp/stscp-\(UUID().uuidString).sock"

        let args = commonControlArgs(for: profile, controlPath: path, password: password)
            + ["-p", String(profile.port), "-f", "-N", "-M", "-o", "ConnectTimeout=15", destination(for: profile)]

        let result = try await run("/usr/bin/ssh", args, try Self.authEnvironment(password: password))
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.connectionFailed(message.isEmpty ? "Unable to establish SSH connection." : message)
        }

        guard connectionAttempt == attempt else {
            let exitArgs = sshOptionArgs(for: profile, controlPath: path, password: password)
                + ["-O", "exit", destination(for: profile)]
            _ = try? await run("/usr/bin/ssh", exitArgs, [:])
            throw CancellationError()
        }
        self.profile = profile
        self.controlPath = path
        self.password = password
    }

    func disconnect() async {
        connectionAttempt = nil
        let profile = self.profile
        let controlPath = self.controlPath
        let password = self.password
        self.profile = nil
        self.controlPath = nil
        self.password = nil
        guard let profile, let controlPath else { return }
        let args = sshOptionArgs(for: profile, controlPath: controlPath, password: password)
            + ["-O", "exit", destination(for: profile)]
        _ = try? await run("/usr/bin/ssh", args, [:])
    }

    func remoteHomeDirectory() async throws -> String {
        let result = try await runRemoteRaw("printf '%s\\n' \"$HOME\"")
        let home = result.stdout.trimmingCharacters(in: .newlines)
        guard result.exitCode == 0, home.hasPrefix("/") else {
            throw SSHError.commandFailed("Cannot determine the remote home directory.")
        }
        return home
    }

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        let result = try await runRemote(["/usr/bin/env", "LC_ALL=C", "TIME_STYLE=locale", "/bin/ls", "-lan", "--", path])
        guard result.exitCode == 0 else {
            throw SSHError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Cannot list \(path)." : result.stderr)
        }
        return Self.parseListing(result.stdout)
    }

    func makeDirectory(_ path: String) async throws {
        try await runChecked(["/bin/mkdir", "-p", "--", path], failureMessage: "Cannot create folder.")
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        let args = isDirectory ? ["/bin/rm", "-rf", "--", path] : ["/bin/rm", "-f", "--", path]
        try await runChecked(args, failureMessage: "Cannot delete \(path).")
    }

    /// `mv` would silently overwrite an existing file or move the item *into* an existing folder,
    /// so refuse when the target already exists (except case-only renames on case-insensitive hosts).
    func rename(from: String, to: String) async throws {
        if from.lowercased() != to.lowercased(), try await itemKinds([to]).first != .missing {
            throw SSHError.commandFailed("An item named \((to as NSString).lastPathComponent) already exists.")
        }
        try await runChecked(["/bin/mv", "--", from, to], failureMessage: "Cannot rename \(from).")
    }

    /// Checks many paths in one round trip. Paths travel as positional arguments to `/bin/sh`,
    /// so the check also works when the login shell is not POSIX (csh, fish). Links to folders
    /// report `.directory`; dangling links report `.file`.
    func itemKinds(_ paths: [String]) async throws -> [RemoteItemKind] {
        guard !paths.isEmpty else { return [] }
        let script = #"for p do if [ -d "$p" ]; then echo d; elif [ -e "$p" ] || [ -L "$p" ]; then echo f; else echo n; fi; done"#
        let result = try await runRemote(["/bin/sh", "-c", script, "sh"] + paths)
        let lines = result.stdout.split(separator: "\n")
        guard result.exitCode == 0, lines.count == paths.count else {
            throw SSHError.commandFailed("Cannot check whether the target items already exist.")
        }
        return lines.map { line in
            switch line {
            case "d": return .directory
            case "f": return .file
            default: return .missing
            }
        }
    }

    /// Tries GNU coreutils `stat` syntax first, then falls back to BSD `stat` (macOS remote hosts).
    func fileSize(at path: String) async -> Int64? {
        if let result = try? await runRemote(["/usr/bin/stat", "-c", "%s", "--", path]),
           result.exitCode == 0,
           let size = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return size
        }
        if let result = try? await runRemote(["/usr/bin/stat", "-f", "%z", "--", path]),
           result.exitCode == 0,
           let size = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return size
        }
        return nil
    }

    /// For folders the parent is the scp target: `scp -r dir host:/x/dir` nests into `/x/dir/dir`
    /// when `/x/dir` already exists, whereas `scp -r dir host:/x` creates or merges `/x/dir`.
    ///
    /// Folders go as one `tar` stream instead (see `transferFolderWithTar`), unless the server has no `tar`.
    func upload(localPath: String, remotePath: String, isDirectory: Bool = false, compress: Bool = false) async throws {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        if isDirectory, try await transferFolderWithTar(.upload, localPath: localPath, remotePath: remotePath, compress: compress) {
            return
        }
        let target = isDirectory ? RemotePath.parent(of: remotePath) : remotePath
        let args = scpOptionArgs(for: profile, controlPath: controlPath, password: password)
            + [localPath, "\(scpHost(for: profile)):\(target)"]
        let result = try await run("/usr/bin/scp", args, try Self.authEnvironment(password: password))
        guard result.exitCode == 0 else {
            throw SSHError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Upload failed." : result.stderr)
        }
    }

    func download(remotePath: String, localPath: String, isDirectory: Bool = false, compress: Bool = false) async throws {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        if isDirectory, try await transferFolderWithTar(.download, localPath: localPath, remotePath: remotePath, compress: compress) {
            return
        }
        let target = isDirectory ? (localPath as NSString).deletingLastPathComponent : localPath
        let args = scpOptionArgs(for: profile, controlPath: controlPath, password: password)
            + ["\(scpHost(for: profile)):\(remotePath)", target]
        let result = try await run("/usr/bin/scp", args, try Self.authEnvironment(password: password))
        guard result.exitCode == 0 else {
            throw SSHError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Download failed." : result.stderr)
        }
    }

    /// Downloads a remote file into its own temporary folder for viewing and makes the copy
    /// read-only, since edits to it are never uploaded back. Links to folders are refused.
    func downloadPreviewCopy(of remotePath: String) async throws -> URL {
        guard try await itemKinds([remotePath]).first == .file else {
            throw SSHError.commandFailed("Only files can be viewed.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stscp-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let name = (remotePath as NSString).lastPathComponent
        let local = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        do {
            try await download(remotePath: remotePath, localPath: local.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: local.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return local
    }

    /// `ssh` arguments for an interactive shell in Terminal that starts in `path`. It rides this
    /// connection's master socket, so no credentials are needed or passed; `ControlMaster=no`
    /// keeps the terminal from becoming a master. If the master is gone, ssh connects on its own
    /// and may prompt in the terminal, hence no `BatchMode`.
    func interactiveShellArguments(startingIn path: String) throws -> [String] {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        var args = [
            "-t",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-p", String(profile.port)
        ]
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if profile.authMethod == .key, !identity.isEmpty {
            args += ["-i", identity]
        }
        // `;` rather than `&&`: a missing folder should still leave the user in a shell.
        let remoteCommand = "cd \(Self.shellEscape(path)); exec \"$SHELL\" -l"
        return args + [destination(for: profile), remoteCommand]
    }

    /// `scp -r` opens and acknowledges every file separately, which dominates when a folder holds
    /// many small files; a single `tar` stream avoids that. Both sides extract into the parent
    /// folder, merging like `scp -r`, with ownership not restored (`-o`). `compress` adds gzip.
    /// Returns `false` when the server has no `tar` (exit 127), so the caller can fall back to scp.
    private func transferFolderWithTar(_ direction: TransferDirection, localPath: String, remotePath: String,
                                       compress: Bool) async throws -> Bool {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        let gzip = compress ? ["-z"] : []
        let localParent = (localPath as NSString).deletingLastPathComponent
        let remoteParent = RemotePath.parent(of: remotePath)
        let ssh = { (remoteArgs: [String]) in
            PipelineStage(executable: "/usr/bin/ssh",
                          arguments: self.sshOptionArgs(for: profile, controlPath: controlPath, password: self.password)
                              + [self.destination(for: profile)] + remoteArgs.map(Self.shellEscape))
        }
        // `./name` keeps names that start with "-" from being read as options.
        let producer: PipelineStage
        let consumer: PipelineStage
        switch direction {
        case .upload:
            // No AppleDouble `._` files or macOS metadata in archives meant for other systems.
            producer = PipelineStage(executable: "/usr/bin/tar", arguments: ["-c", "--no-mac-metadata", "--no-xattrs"]
                + gzip + ["-f", "-", "-C", localParent, "./" + (localPath as NSString).lastPathComponent])
            consumer = ssh(["tar", "-x", "-o"] + gzip + ["-f", "-", "-C", remoteParent])
        case .download:
            producer = ssh(["tar", "-c"] + gzip + ["-f", "-", "-C", remoteParent, "./" + (remotePath as NSString).lastPathComponent])
            consumer = PipelineStage(executable: "/usr/bin/tar", arguments: ["-x", "-o"] + gzip + ["-f", "-", "-C", localParent])
        }
        let environment = try Self.authEnvironment(password: password).merging(["COPYFILE_DISABLE": "1"]) { $1 }
        let (produced, consumed) = try await runPipeline(producer, consumer, environment)

        let remoteResult = direction == .upload ? consumed : produced
        if remoteResult.exitCode == 127 { return false }
        for result in [produced, consumed] where result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(message.isEmpty
                ? (direction == .upload ? "Upload failed." : "Download failed.") : message)
        }
        return true
    }

    // MARK: - Command plumbing

    private func runChecked(_ commandArgs: [String], failureMessage: String) async throws {
        let result = try await runRemote(commandArgs)
        guard result.exitCode == 0 else {
            throw SSHError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? failureMessage : result.stderr)
        }
    }

    private func runRemote(_ commandArgs: [String]) async throws -> ProcessResult {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        let args = sshOptionArgs(for: profile, controlPath: controlPath, password: password)
            + [destination(for: profile)]
            + commandArgs.map(Self.shellEscape)
        return try await run("/usr/bin/ssh", args, try Self.authEnvironment(password: password))
    }

    /// For commands that rely on remote shell expansion (e.g. `~`) and must not be quoted.
    private func runRemoteRaw(_ command: String) async throws -> ProcessResult {
        guard let profile, let controlPath else { throw SSHError.notConnected }
        let args = sshOptionArgs(for: profile, controlPath: controlPath, password: password)
            + [destination(for: profile), command]
        return try await run("/usr/bin/ssh", args, try Self.authEnvironment(password: password))
    }

    private func destination(for profile: SiteProfile) -> String {
        "\(profile.username)@\(profile.host)"
    }

    /// scp splits `host:path` at the first colon, so IPv6 literals must be bracketed.
    private func scpHost(for profile: SiteProfile) -> String {
        let host = profile.host.contains(":") && !profile.host.hasPrefix("[") ? "[\(profile.host)]" : profile.host
        return "\(profile.username)@\(host)"
    }

    /// Key/agent sites keep `BatchMode=yes` so ssh never prompts. Password sites must allow
    /// prompts, which `SSH_ASKPASS` answers (see `authEnvironment`); one attempt avoids
    /// repeating a wrong password and tripping server-side lockouts.
    private func commonControlArgs(for profile: SiteProfile, controlPath: String, password: String?) -> [String] {
        let authArgs = password == nil
            ? ["-o", "BatchMode=yes"]
            : ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1",
               "-o", "PreferredAuthentications=keyboard-interactive,password"]
        var args = authArgs + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(controlPath)"
        ]
        let identity = profile.identityFile.trimmingCharacters(in: .whitespaces)
        if profile.authMethod == .key, !identity.isEmpty {
            args += ["-i", identity]
        }
        return args
    }

    private func sshOptionArgs(for profile: SiteProfile, controlPath: String, password: String?) -> [String] {
        commonControlArgs(for: profile, controlPath: controlPath, password: password) + ["-p", String(profile.port)]
    }

    private func scpOptionArgs(for profile: SiteProfile, controlPath: String, password: String?) -> [String] {
        commonControlArgs(for: profile, controlPath: controlPath, password: password)
            + ["-P", String(profile.port), "-p", "-r"]
    }

    // MARK: - Password authentication

    static let passwordEnvironmentKey = "STSCP_SSH_PASSWORD"

    /// ssh asks the `SSH_ASKPASS` program for the password; the helper only echoes an
    /// environment variable, so the password never touches disk or the argument list
    /// (visible to every user via `ps`). The environment is readable only by this user.
    static func authEnvironment(password: String?) throws -> [String: String] {
        guard let password else { return [:] }
        guard let helper = askpassHelperPath else {
            throw SSHError.connectionFailed("Cannot prepare password authentication helper.")
        }
        return [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            passwordEnvironmentKey: password
        ]
    }

    /// Written once per launch into the per-user temporary directory with owner-only
    /// permissions. It contains no secret.
    private static let askpassHelperPath: String? = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stscp-askpass-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvironmentKey)\"\n"
        do {
            try Data(script.utf8).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }()

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - `ls -la` parsing

    private static let listingRegex = try! NSRegularExpression(
        pattern: #"^([-dlbcps])([-rwxsStT]{9})[.+@]?\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.*)$"#
    )

    static func parseListing(_ output: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("total ") { continue }

            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = listingRegex.firstMatch(in: line, range: fullRange) else { continue }

            func group(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: line) else { return "" }
                return String(line[range])
            }

            let typeChar = group(1)
            let permissions = typeChar + group(2)
            let size = Int64(group(6)) ?? 0
            let modifiedRaw = group(7)
            var name = group(8)
            let isSymlink = typeChar == "l"

            if isSymlink, let arrowRange = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrowRange.lowerBound])
            }

            if name == "." || name == ".." { continue }

            entries.append(RemoteEntry(
                name: name,
                isDirectory: typeChar == "d",
                isSymlink: isSymlink,
                size: size,
                modifiedRaw: modifiedRaw,
                permissions: permissions
            ))
        }

        return entries
    }
}
