# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).


## [0.1.0] - 2026-11-15

### Added

- Two-pane SwiftUI SFTP client: local file browser and remote browser over SSH.
- SSH key / ssh-agent authentication using a shared OpenSSH ControlMaster connection.
- Upload and download via `scp` with a transfer queue and progress reporting.
- Remote and local mkdir, rename and delete; drag and drop between panes.
- Saved site profiles in `~/Library/Application Support/Stscp/sites.json`.
- Password authentication per site. The password is kept in memory for the current app
  session only and is never saved to disk or the Keychain.
