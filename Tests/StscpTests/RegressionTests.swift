// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import Stscp

private func listing(_ name: String) -> String {
    "-rw-r--r-- 1 501 20 42 Nov 13 10:15 \(name)\n"
}

/// Controlled suspension makes races reproducible without contacting an SSH server.
private actor CommandStub {
    private(set) var calls: [(String, [String])] = []
    private var blockNext = false
    private var blockConnection = false
    private var blockTransfer = false
    private var pending: CheckedContinuation<ProcessResult, Never>?

    var isBlocked: Bool { pending != nil }
    func blockNextListing() { blockNext = true }
    func blockNextConnection() { blockConnection = true }
    func blockNextTransfer() { blockTransfer = true }
    func release() {
        pending?.resume(returning: ProcessResult(exitCode: 0, stdout: listing("old.txt"), stderr: ""))
        pending = nil
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        calls.append((executable, arguments))
        if blockConnection && arguments.contains("-M") {
            blockConnection = false
            return await withCheckedContinuation { pending = $0 }
        }
        if blockTransfer && executable == "/usr/bin/scp" {
            blockTransfer = false
            return await withCheckedContinuation { pending = $0 }
        }
        if arguments.contains("'/bin/ls'") {
            if blockNext {
                blockNext = false
                return await withCheckedContinuation { pending = $0 }
            }
            return ProcessResult(exitCode: 0, stdout: listing("new.txt"), stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: "/home/test\n", stderr: "")
    }
}

private func profile(host: String = "first.example") -> SiteProfile {
    var value = SiteProfile()
    value.host = host
    value.username = "tester"
    return value
}

@Suite(.timeLimit(.minutes(1)))
struct ProcessRegressionTests {
    @Test func capturesBothPipesAndExitStatus() async throws {
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: [
            "-c", "i=0; while [ $i -lt 5000 ]; do printf 'stdout-data\\n'; printf 'stderr-data\\n' >&2; i=$((i+1)); done; exit 7"
        ])
        #expect(result.exitCode == 7)
        #expect(result.stdout == String(repeating: "stdout-data\n", count: 5000))
        #expect(result.stderr == String(repeating: "stderr-data\n", count: 5000))
    }

    @Test func capturesShortLivedProcesses() async throws {
        for _ in 0..<30 {
            let result = try await ProcessRunner.run(executable: "/bin/echo", arguments: ["tail"])
            #expect(result.stdout == "tail\n")
        }
    }

    @Test func invalidExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(executable: "/nonexistent/stscp-test", arguments: [])
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ModelRegressionTests {
    @Test func progressCannotReopenTerminalTransfers() {
        let task = TransferTask(direction: .upload, name: "file")
        task.state = .running(progress: 0)
        task.updateProgress(0.5)
        #expect(task.state == .running(progress: 0.5))
        task.state = .completed
        task.updateProgress(0.9)
        #expect(task.state == .completed)
        task.state = .failed("failed")
        task.updateProgress(1)
        #expect(task.state == .failed("failed"))
    }

    @Test func trashPermissionErrorsPointToPrivacySettings() {
        // Shape observed from FileManager.trashItem when TCC denies access to ~/Downloads.
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -5000)
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(TransferQueue.isPrivacyDenial(denied))
        #expect(TransferQueue.describe(denied).contains("Privacy & Security"))
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(!TransferQueue.isPrivacyDenial(other))
    }

    @Test func clearFinishedRemovesFailedButKeepsActiveTransfers() {
        let queue = TransferQueue()
        let states: [TransferState] = [.completed, .failed("Failure"), .queued, .running(progress: 0.3)]
        queue.tasks = states.map { state in
            let task = TransferTask(direction: .upload, name: "file")
            task.state = state
            return task
        }
        queue.clearFinished()
        #expect(queue.tasks.map(\.state) == [.queued, .running(progress: 0.3)])
        queue.tasks.forEach { $0.state = .failed("x") }
        queue.clearFinished()
        #expect(queue.tasks.isEmpty)
    }

    @Test func localRenameToSameNameDoesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("example.txt")
        try Data("content".utf8).write(to: file)
        let model = LocalPanelModel(url: folder)
        model.selection = Set(model.items.filter { $0.name == "example.txt" }.map(\.id))
        #expect(model.selection.count == 1)
        model.renameSelected(to: "example.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["example.txt"])
        #expect(model.error == nil)
        model.createFolder(named: "..")
        #expect(model.error != nil)
    }

    @Test func staleListingCannotReplaceNewDirectory() async throws {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        await model.connect(to: profile())
        await stub.blockNextListing()
        let old = Task { await model.navigate(to: "/old") }
        while !(await stub.isBlocked) { await Task.yield() }
        await model.navigate(to: "/new")
        await stub.release()
        await old.value
        #expect(model.currentPath == "/new")
        #expect(model.items.map(\.path) == ["/new/new.txt"])
        #expect(!model.isBusy)
    }

    @Test func disconnectInvalidatesPendingListing() async {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        await model.connect(to: profile())
        await stub.blockNextListing()
        let reload = Task { await model.reload() }
        while !(await stub.isBlocked) { await Task.yield() }
        await model.disconnect()
        await stub.release()
        await reload.value
        #expect(model.connectionState == .disconnected)
        #expect(model.items.isEmpty)
        #expect(!model.isBusy)
    }

    @Test func switchingServersDoesNotRetargetOldSession() async throws {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        await model.connect(to: profile())
        let original = model.session
        await model.connect(to: profile(host: "second.example"))
        await #expect(throws: SSHError.self) {
            try await original.upload(localPath: "/tmp/test", remotePath: "/tmp/test")
        }
        let calls = await stub.calls
        #expect(!calls.contains { $0.0 == "/usr/bin/scp" })
        let masters = calls.filter { $0.1.contains("-M") }
        #expect(masters.count == 2)
        let sockets = masters.compactMap { $0.1.first { $0.hasPrefix("ControlPath=") } }
        #expect(Set(sockets).count == 2)
    }

    @Test func queuedTransfersNeverSwitchServers() async {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        await model.connect(to: profile())
        let queue = TransferQueue()
        await stub.blockNextTransfer()
        for name in ["one", "two"] {
            queue.enqueueUpload(session: model.session,
                                localURL: URL(fileURLWithPath: "/nonexistent/" + name),
                                remotePath: "/tmp/" + name, isDirectory: false, completion: {})
        }
        while !(await stub.isBlocked) { await Task.yield() }
        await model.connect(to: profile(host: "second.example"))
        await stub.release()
        while queue.tasks.contains(where: {
            switch $0.state {
            case .queued, .running: return true
            default: return false
            }
        }) { await Task.yield() }
        #expect(queue.tasks[0].state == .completed)
        if case .failed = queue.tasks[1].state {} else { Issue.record("Disconnected transfer should fail") }
        let transfers = await stub.calls.filter { $0.0 == "/usr/bin/scp" }
        #expect(transfers.count == 1)
        #expect(transfers.first?.1.contains("tester@first.example:/tmp/one") == true)
    }

    @Test func disconnectDuringConnectDoesNotRestoreConnection() async {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        await stub.blockNextConnection()
        let connecting = Task { await model.connect(to: profile()) }
        while !(await stub.isBlocked) { await Task.yield() }
        let abandoned = model.session
        await model.disconnect()
        await stub.release()
        await connecting.value
        #expect(model.connectionState == .disconnected)
        #expect(await abandoned.isConnected == false)
        #expect(model.items.isEmpty)
        let calls = await stub.calls
        #expect(calls.contains { $0.1.contains("-O") && $0.1.contains("exit") })
    }

    @Test func missingHomeFailsInsteadOfNavigatingToRoot() async {
        let model = RemotePanelModel(makeSession: {
            SSHSession(run: { _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") })
        })
        await model.connect(to: profile())
        if case .failed = model.connectionState {} else { Issue.record("Missing home must fail") }
        #expect(model.currentPath == ".")
        #expect(await model.session.isConnected == false)
    }

    @Test func relativeInitialDirectoryAndEntryValidation() async {
        let stub = CommandStub()
        let model = RemotePanelModel(makeSession: { SSHSession(run: { try await stub.run($0, $1) }) })
        var site = profile()
        site.remotePath = "documents"
        await model.connect(to: site)
        #expect(model.currentPath == "/home/test/documents")
        let calls = await stub.calls
        #expect(calls.contains { $0.1.contains("'LC_ALL=C'") && $0.1.contains("'TIME_STYLE=locale'") && $0.1.contains("'-lan'") })
        let before = await stub.calls.count
        await model.createFolder(named: "../escape")
        let after = await stub.calls.count
        #expect(before == after)
        #expect(model.error != nil)
    }
}

struct InputRegressionTests {
    @Test func rejectsInvalidConnectionSettings() {
        var site = profile()
        #expect(site.isValid)
        site.port = 0
        #expect(!site.isValid)
        site.port = 65536
        #expect(!site.isValid)
        site.port = 22
        site.host = " host "
        #expect(!site.isValid)
        site.host = "server.example"
        site.username = "-oProxyCommand=bad"
        #expect(!site.isValid)
    }

    @Test func normalizesRemotePaths() {
        #expect(RemotePath.resolve("../other/./file", relativeTo: "/home/test") == "/home/other/file")
        #expect(RemotePath.resolve("/../../etc", relativeTo: "/home/test") == "/etc")
        #expect(RemotePath.resolve(".", relativeTo: "/home/test") == "/home/test")
    }

    @Test func parsesNumericListingsAndSymlinks() {
        let entries = SSHSession.parseListing("""
        total 8
        drwxr-xr-x 2 501 20 64 Nov 13 10:15 .
        -rw-r--r--@ 1 501 20 42 Nov 13 10:15 file with spaces.txt
        lrwxr-xr-x 1 501 20 4 Nov 13 2025 link -> dest
        """)
        #expect(entries.map(\.name) == ["file with spaces.txt", "link"])
        #expect(entries.last?.isSymlink == true)
    }
}

/// Records every command; listings of `missingPath` fail and the existence check reports
/// `existing` files and `existingFolders`.
private actor ScriptedServer {
    private(set) var calls: [(String, [String])] = []
    var missingPath = "/missing"
    var existing: Set<String> = []
    var existingFolders: Set<String> = []

    func setExisting(_ paths: Set<String>, folders: Set<String> = []) {
        existing = paths
        existingFolders = folders
    }

    func run(_ executable: String, _ arguments: [String]) -> ProcessResult {
        calls.append((executable, arguments))
        if let shell = arguments.firstIndex(of: "'/bin/sh'"), arguments.count > shell + 3 {
            let paths = arguments[(shell + 4)...].map { String($0.dropFirst().dropLast()) }
            let kinds = paths.map { existingFolders.contains($0) ? "d" : existing.contains($0) ? "f" : "n" }
            return ProcessResult(exitCode: 0, stdout: kinds.map { $0 + "\n" }.joined(), stderr: "")
        }
        if arguments.contains("'/bin/ls'") {
            if arguments.contains("'\(missingPath)'") {
                return ProcessResult(exitCode: 2, stdout: "", stderr: "No such file or directory")
            }
            return ProcessResult(exitCode: 0, stdout: listing("file.txt"), stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: "/home/test\n", stderr: "")
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ReviewRegressionTests {
    private func connectedModel(_ server: ScriptedServer) async -> RemotePanelModel {
        let model = RemotePanelModel(makeSession: { SSHSession(run: { await server.run($0, $1) }) })
        await model.connect(to: profile())
        return model
    }

    @Test func failedNavigationReturnsToPreviousFolder() async {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        #expect(model.currentPath == "/home/test")
        await model.navigate(to: "/missing")
        #expect(model.currentPath == "/home/test")
        #expect(model.items.map(\.name) == ["file.txt"])
        #expect(model.error != nil)
    }

    @Test func remoteRenameRefusesExistingTarget() async {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        await server.setExisting(["/home/test/taken"])
        model.selection = ["/home/test/file.txt"]
        await model.renameSelected(to: "taken")
        #expect(model.error?.message.contains("already exists") == true)
        #expect(!(await server.calls).contains { $0.1.contains("'/bin/mv'") })
    }

    @Test func reportsRemoteItemKindsInOneCall() async throws {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        await server.setExisting(["/home/test/a file.txt"], folders: ["/home/test/dir"])
        let before = await server.calls.count
        let kinds = try await model.session.itemKinds(["/home/test/a file.txt", "/home/test/dir", "/home/test/new"])
        #expect(kinds == [.file, .directory, .missing])
        #expect(await server.calls.count == before + 1)
    }

    @Test func folderTransfersTargetParentDirectory() async throws {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        try await model.session.upload(localPath: "/local/dir", remotePath: "/home/test/dir", isDirectory: true)
        try await model.session.download(remotePath: "/home/test/dir", localPath: "/local/dl/dir", isDirectory: true)
        let scp = await server.calls.filter { $0.0 == "/usr/bin/scp" }.map(\.1)
        #expect(scp.first?.suffix(2) == ["/local/dir", "tester@first.example:/home/test"])
        #expect(scp.last?.suffix(2) == ["tester@first.example:/home/test/dir", "/local/dl"])
    }

    @Test func siteStoreToleratesMissingKeysAndKeepsCorruptFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sites.json")
        try Data(#"[{"name":"Old","host":"old.example","username":"me"}]"#.utf8).write(to: url)
        let store = SiteStore(storeURL: url)
        #expect(store.sites.map(\.host) == ["old.example"])
        #expect(store.sites.first?.port == 22)

        try Data("not json".utf8).write(to: url)
        _ = SiteStore(storeURL: url)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.contains { $0.hasPrefix("sites.corrupt-") })
    }

    @Test func caseOnlyLocalRenameKeepsRequestedName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("readme.txt")
        try Data("x".utf8).write(to: file)
        let model = LocalPanelModel(url: folder)
        model.selection = Set(model.items.filter { $0.name == "readme.txt" }.map(\.id))
        #expect(model.selection.count == 1)
        model.renameSelected(to: "README.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["README.txt"])
    }

    private func waitUntilFinished(_ queue: TransferQueue) async {
        while queue.tasks.contains(where: {
            switch $0.state {
            case .queued, .running: return true
            default: return false
            }
        }) { await Task.yield() }
    }

    @Test func moveKeepsSourceWhenCopyCannotBeVerified() async throws {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("keep.txt")
        try Data("content".utf8).write(to: file)
        let queue = TransferQueue()
        // The stub's `stat` reply is not a number, so the remote size cannot be confirmed.
        queue.enqueueUpload(session: model.session, localURL: file, remotePath: "/home/test/keep.txt",
                            isDirectory: false, moveSource: true, completion: {})
        await waitUntilFinished(queue)
        if case .failed(let message) = queue.tasks[0].state {
            #expect(message.contains("source was kept"))
        } else {
            Issue.record("Unverified move must not report success")
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func verifiedMoveDeletesRemoteSource() async throws {
        let server = ScriptedServer()
        let model = await connectedModel(server)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("data.bin")
        try Data("1234".utf8).write(to: local) // stands in for what scp wrote
        let queue = TransferQueue()
        queue.enqueueDownload(session: model.session, remotePath: "/home/test/data.bin", localURL: local,
                              remoteSize: 4, isDirectory: false, moveSource: true, completion: {})
        await waitUntilFinished(queue)
        #expect(queue.tasks[0].state == .completed)
        let calls = await server.calls
        #expect(calls.contains { $0.1.contains("'/bin/rm'") && $0.1.contains("'/home/test/data.bin'") })
    }
}

/// Records the extra environment passed to ssh/scp so password handling can be checked.
private actor EnvironmentStub {
    private(set) var calls: [(executable: String, arguments: [String], environment: [String: String])] = []
    var failConnection = false

    func failNextConnection() { failConnection = true }

    func run(_ executable: String, _ arguments: [String], _ environment: [String: String]) -> ProcessResult {
        calls.append((executable, arguments, environment))
        if failConnection && arguments.contains("-M") {
            failConnection = false
            return ProcessResult(exitCode: 255, stdout: "", stderr: "Permission denied (password).")
        }
        if arguments.contains("'/bin/ls'") {
            return ProcessResult(exitCode: 0, stdout: listing("file.txt"), stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: "/home/test\n", stderr: "")
    }
}

private func passwordProfile() -> SiteProfile {
    var site = profile()
    site.authMethod = .password
    site.identityFile = "/Users/tester/.ssh/id_ed25519"
    return site
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PasswordAuthRegressionTests {
    @Test func passwordTravelsOnlyThroughAskpassEnvironment() async throws {
        let stub = EnvironmentStub()
        let session = SSHSession(runWithEnvironment: { await stub.run($0, $1, $2) })
        let secret = "s3cr'et pass"
        try await session.connect(passwordProfile(), password: secret)
        _ = try await session.listDirectory("/home/test")
        try await session.upload(localPath: "/tmp/a.txt", remotePath: "/home/test/a.txt")

        let calls = await stub.calls
        let authenticated = calls.filter { !$0.arguments.contains("-O") }
        #expect(authenticated.count == 3)
        for call in calls {
            #expect(!call.arguments.contains { $0.contains(secret) })
            #expect(call.arguments.contains("BatchMode=no"))
            #expect(!call.arguments.contains("-i"))
        }
        for call in authenticated {
            #expect(call.environment[SSHSession.passwordEnvironmentKey] == secret)
            #expect(call.environment["SSH_ASKPASS_REQUIRE"] == "force")
        }
    }

    @Test func askpassHelperPrintsPasswordAndContainsNoSecret() async throws {
        let secret = "p@ss word $HOME `x`"
        let environment = try SSHSession.authEnvironment(password: secret)
        let helper = try #require(environment["SSH_ASKPASS"])
        let contents = try String(contentsOfFile: helper, encoding: .utf8)
        #expect(!contents.contains(secret))
        let attributes = try FileManager.default.attributesOfItem(atPath: helper)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.environment = [SSHSession.passwordEnvironmentKey: secret]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == secret + "\n")
    }

    @Test func keySitesKeepBatchModeAndIgnorePassword() async throws {
        let stub = EnvironmentStub()
        let session = SSHSession(runWithEnvironment: { await stub.run($0, $1, $2) })
        var site = profile()
        site.identityFile = "/Users/tester/.ssh/id_ed25519"
        try await session.connect(site, password: "unused")
        let calls = await stub.calls
        #expect(calls.allSatisfy { $0.arguments.contains("BatchMode=yes") && $0.environment.isEmpty })
        #expect(calls.first?.arguments.contains("-i") == true)
    }

    @Test func emptyPasswordIsRejectedWithoutRunningSSH() async {
        let stub = EnvironmentStub()
        let session = SSHSession(runWithEnvironment: { await stub.run($0, $1, $2) })
        await #expect(throws: SSHError.self) { try await session.connect(passwordProfile(), password: "") }
        #expect(await stub.calls.isEmpty)
    }

    @Test func passwordIsRememberedOnSuccessAndForgottenOnFailure() async {
        let site = passwordProfile()
        defer { SessionPasswords.shared.remove(for: site.id) }
        let stub = EnvironmentStub()
        let model = RemotePanelModel(makeSession: { SSHSession(runWithEnvironment: { await stub.run($0, $1, $2) }) })

        await model.connect(to: site, password: "good")
        #expect(model.connectionState == .connected)
        #expect(SessionPasswords.shared.password(for: site.id) == "good")

        await stub.failNextConnection()
        await model.connect(to: site, password: "wrong")
        if case .failed = model.connectionState {} else { Issue.record("Rejected password must fail") }
        #expect(SessionPasswords.shared.password(for: site.id) == nil)
    }

    @Test func passwordIsNeverWrittenToSitesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let site = passwordProfile()
        SessionPasswords.shared.set("top-secret", for: site.id)
        defer { SessionPasswords.shared.remove(for: site.id) }
        let store = SiteStore(storeURL: url)
        store.upsert(site)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("top-secret"))
        #expect(json.contains("\"authMethod\":\"password\""))
        #expect(SiteStore(storeURL: url).sites.first?.authMethod == .password)
    }

    @Test func olderSitesDefaultToKeyAuthentication() throws {
        let json = #"[{"name":"Old","host":"h.example","port":22,"username":"u"}]"#
        let sites = try JSONDecoder().decode([SiteProfile].self, from: Data(json.utf8))
        #expect(sites.first?.authMethod == .key)
    }
}
