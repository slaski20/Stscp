// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum AuthMethod: String, Codable, Hashable, Sendable, CaseIterable {
    /// SSH keys or ssh-agent (`BatchMode=yes`).
    case key
    /// Password typed when connecting; kept in memory only (see `SessionPasswords`).
    case password
}

struct SiteProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Site"
    var host: String = ""
    var port: Int = 22
    var username: String = NSUserName()
    var authMethod: AuthMethod = .key
    var identityFile: String = ""
    var remotePath: String = "."

    var isValid: Bool {
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !host.isEmpty && !username.isEmpty && (1...65535).contains(port) &&
            host.rangeOfCharacter(from: invalid) == nil &&
            username.rangeOfCharacter(from: invalid) == nil &&
            !host.contains("@") && !username.contains("@") && !username.hasPrefix("-")
    }

    var subtitle: String {
        "\(username)@\(host):\(port)"
    }
}

extension SiteProfile {
    /// Missing keys (older or hand-edited files) fall back to defaults instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SiteProfile()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        authMethod = (try? container.decodeIfPresent(AuthMethod.self, forKey: .authMethod)) ?? defaults.authMethod
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? defaults.identityFile
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? defaults.remotePath
    }
}

/// Passwords typed in the Site Manager, keyed by site. They live only in this process's
/// memory: never written to `sites.json`, the Keychain, or any other file, and gone on quit.
@MainActor
final class SessionPasswords {
    static let shared = SessionPasswords()

    private var passwords: [SiteProfile.ID: String] = [:]

    func password(for id: SiteProfile.ID) -> String? { passwords[id] }

    func set(_ password: String, for id: SiteProfile.ID) { passwords[id] = password }

    func remove(for id: SiteProfile.ID) { passwords[id] = nil }
}

@MainActor
final class SiteStore: ObservableObject {
    @Published var sites: [SiteProfile] = []

    private let storeURL: URL

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("Stscp", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("sites.json")
            Self.migrateLegacyStore(to: self.storeURL, appSupport: appSupport)
        }
        load()
    }

    /// The app was called TotalScp before; copy (not move) its sites so the old build keeps working.
    private static func migrateLegacyStore(to storeURL: URL, appSupport: URL) {
        let legacy = appSupport.appendingPathComponent("TotalScp/sites.json")
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: storeURL.path), fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.copyItem(at: legacy, to: storeURL)
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            sites = try JSONDecoder().decode([SiteProfile].self, from: data)
        } catch {
            // Keep the unreadable file: the next save would otherwise replace every saved site.
            let backup = storeURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: storeURL, to: backup)
            sites = []
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func upsert(_ site: SiteProfile) {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = site
        } else {
            sites.append(site)
        }
        save()
    }

    func delete(_ site: SiteProfile) {
        sites.removeAll { $0.id == site.id }
        save()
    }
}
