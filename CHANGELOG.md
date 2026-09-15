# Changelog

All notable changes to AI Usage MB are documented in this file.

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
