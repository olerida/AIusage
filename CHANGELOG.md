# Changelog

All notable changes to AI Usage MB are documented in this file.

## [1.4.0] - 2026-09-17

### Added

- Independent notification thresholds for the 5-hour and weekly Codex windows.
- Configurable notifications before saved reset credits expire.
- Continuous Codex alert monitoring while GitHub Copilot is the visible agent.

### Changed

- The active-agent picker now lives in the main panel instead of Settings.
- Codex and Copilot display settings are always available in the General tab.
- Notification permission is requested when notifications are enabled.

### Fixed

- Alerts are recorded only after macOS accepts them, so disabled or failed notifications can retry.
- Codex menu-bar content now follows the system foreground color and remains visible in every appearance.

## [1.3.0] - 2026-09-16

### Added

- GitHub Copilot plan, credit quota, progress bar, reset date, and independent menu-bar display toggles.

### Fixed

- Prevent repeated Keychain prompts by caching GitHub credentials for the process lifetime.
- Prevent the empty SwiftUI Settings window from appearing when the menu-bar app starts.

## [1.2.2] - 2026-09-16

### Fixed

- Package validation now accepts both flat and versioned SwiftPM resource-bundle layouts used by supported Xcode releases.

## [1.2.1] - 2026-09-15

### Fixed

- Release packages now place the SwiftPM resource bundle at its runtime lookup path, preventing startup crashes outside the build machine.

## [1.2.0] - 2026-09-15

### Added

- Codex token usage by model for the last 30 days, with input, output, and cache totals.

### Fixed

- The menu-bar popover now closes reliably when clicking anywhere outside it.
- Universal packaging now isolates Apple Silicon and Intel build outputs.

## [1.1.0] - 2026-09-09

### Added

- GitHub Copilot account connection through GitHub's device flow.
- Monthly personal premium-request and AI-credit usage from GitHub's official billing API.
- Per-model Copilot usage when the API supplies model data.
- Secure GitHub token storage in the macOS Keychain.
- Agent picker and separate Agent and General settings tabs.

### Changed

- The popover identity, account details, status text, and external usage action now follow the selected agent.
- Covered Copilot activity now shows its gross usage separately from the amount actually billed.
- Unavailable Copilot metrics are omitted instead of showing empty placeholders.
- The visible app name, bundle, documentation, and GitHub integration are now “AI Usage MB”.

## [1.0.1] - 2026-09-08

### Added

- GitHub repository link and developer credit in the About window.
- Homebrew installation through `olerida/tap/aiusage`.

### Changed

- The popover identifies the monitored agent as Codex.
- The reload control now matches the other toolbar buttons.
- The About window uses the spaced “AI usage” display name.

## [1.0.0] - 2026-09-07

### Added

- Native macOS menu-bar app for Codex usage monitoring.
- Separate 5-hour and weekly usage windows and menu-bar controls.
- Reset-credit expiry filtering and three-day warning state.
- Daily, weekly, and cumulative token-usage heatmaps.
- Adaptive popover sizing, settings, about screen, notifications, and launch at login.
- Spanish, Catalan, and English localization.
- Universal packaging, code-signing, notarization, and GitHub release tooling.
- New AIusage identity and Apple-style production icon.
