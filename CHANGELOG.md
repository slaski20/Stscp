# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).


## [0.1.1] - 2026-11-18

### Added

- Open Terminal (⌥⌘T): opens Terminal in the active panel's folder, or an SSH shell in the
  current remote folder that reuses the existing connection without asking for the password again.
- View in Editor (F3): opens the selected file in a configurable editor (TextEdit by default);
  remote files are opened as a temporary read-only copy.
- Settings window (⌘,) for the editor, the number of parallel transfers and folder compression.
- Up to four transfers run in parallel (three by default).
- Folders are transferred as a single `tar` stream, which is much faster for many small files,
  with optional gzip compression. Servers without `tar` fall back to `scp -r`.

### Changed

- Symbolic links inside transferred folders are now copied as links instead of being followed.

### Fixed

- Dragging files between the local and remote panels starts the transfer again.

## [0.1.0] - 2026-11-15

### Added

- Two-pane SwiftUI SFTP client: local file browser and remote browser over SSH.
- SSH key / ssh-agent authentication using a shared OpenSSH ControlMaster connection.
- Upload and download via `scp` with a transfer queue and progress reporting.
- Remote and local mkdir, rename and delete; drag and drop between panes.
- Saved site profiles in `~/Library/Application Support/Stscp/sites.json`.
- Password authentication per site. The password is kept in memory for the current app
  session only and is never saved to disk or the Keychain.
