# Changelog

Important changes to this project are documented here.

## [Unreleased]

## [1.0.0] - 2026-04-28

### Added

- Initial Codux Mobile Flutter client for connecting to Codux on macOS through the relay service.
- Added QR pairing, device management, project switching, terminal split switching, file browsing, image upload, and AI usage panels.
- Added native Android terminal rendering through a Termux TerminalView based Flutter platform view, including remote output, user input, scrollback, text selection, quick keys, and IME avoidance.
- Added GitHub update checking against the latest `duxweb/codux-flutter` release.

### Changed

- Replaced the earlier WebView / xterm rendering direction with the native Android terminal plugin.
- Added release logging control through `CODUX_LOG_LEVEL`, shared by Flutter and the native terminal plugin.

### Fixed

- Stabilized Android keyboard avoidance for terminal TUI apps by shifting the terminal surface without forcing remote terminal resize.
- Fixed remote terminal input duplication and emulator response forwarding by separating user input from local terminal responses.
