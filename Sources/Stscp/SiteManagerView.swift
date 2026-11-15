// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

struct SiteManagerView: View {
    @ObservedObject var store: SiteStore
    /// The password is passed only for password sites and is never stored in the profile.
    let onConnect: (SiteProfile, String?) -> Void
    let onClose: () -> Void

    @State private var selectedID: SiteProfile.ID?
    @State private var draft = SiteProfile()
    /// An untouched blank form shown when no site exists; it is not saved until edited.
    @State private var placeholder: SiteProfile?
    /// Kept outside `draft`, so the autosave below can never write it to `sites.json`.
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Site Manager")
                .font(.title3.bold())
                .padding(12)
            Divider()

            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }

            Divider()
            HStack {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    store.upsert(draft)
                    onConnect(draft, draft.authMethod == .password ? password : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
            .padding(12)
        }
        .frame(width: 640, height: 440)
        .onAppear {
            if let first = store.sites.first {
                selectedID = first.id
                draft = first
            } else {
                placeholder = draft
            }
            loadPassword()
        }
        .onChange(of: draft.id) { _ in loadPassword() }
    }

    private var canConnect: Bool {
        draft.isValid && (draft.authMethod == .key || !password.isEmpty)
    }

    private func loadPassword() {
        password = SessionPasswords.shared.password(for: draft.id) ?? ""
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(store.sites, selection: $selectedID) { site in
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                    Text(site.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(site.id)
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { id in
                if let id, let site = store.sites.first(where: { $0.id == id }) {
                    draft = site
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button {
                    let new = SiteProfile()
                    store.upsert(new)
                    selectedID = new.id
                    draft = new
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add site")

                Button {
                    guard let id = selectedID, let site = store.sites.first(where: { $0.id == id }) else { return }
                    store.delete(site)
                    SessionPasswords.shared.remove(for: site.id)
                    selectedID = store.sites.first?.id
                    if let first = store.sites.first {
                        draft = first
                    } else {
                        // Without this the autosave below would immediately recreate a "New Site".
                        let blank = SiteProfile()
                        placeholder = blank
                        draft = blank
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                .help("Remove site")

                Spacer()
            }
            .padding(8)
        }
        .frame(width: 200)
    }

    private var detail: some View {
        Form {
            Section("Site") {
                TextField("Name", text: $draft.name)
                TextField("Host", text: $draft.host)
                TextField("Port", value: $draft.port, formatter: NumberFormatter())
                TextField("Username", text: $draft.username)
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authMethod) {
                    Text("SSH key / agent").tag(AuthMethod.key)
                    Text("Password").tag(AuthMethod.password)
                }
                .pickerStyle(.segmented)

                switch draft.authMethod {
                case .key:
                    Text("Uses SSH keys or ssh-agent. Leave the identity file empty to rely on your default keys / agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Identity file (optional)", text: $draft.identityFile)
                        Button("Choose...") { chooseIdentityFile() }
                    }
                case .password:
                    SecureField("Password", text: $password)
                    Text("Kept in memory only until Stscp quits. It is never saved to disk or the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote Path") {
                TextField("Initial directory (. for home)", text: $draft.remotePath)
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { newValue in
            guard newValue != placeholder else { return }
            placeholder = nil
            store.upsert(newValue)
            if selectedID != newValue.id { selectedID = newValue.id }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }
}
