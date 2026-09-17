# AI Usage MB

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Version](https://img.shields.io/badge/version-v1.4.1-0A84FF)
![License](https://img.shields.io/badge/license-MIT-34C759)

<p align="center">
  <img src="Resources/AppIcon.png" width="180" alt="AI Usage MB app icon">
</p>

AI Usage MB (AI Usage Menu Bar) is a native macOS menu-bar utility for monitoring Codex and GitHub Copilot without keeping a dashboard open.

## Highlights

- Independent 5-hour and weekly usage meters.
- Optional 5-hour and weekly percentages in the menu bar.
- Reset-credit list with expired credits hidden and a configurable expiry-warning period.
- Daily, weekly, and cumulative token-usage heatmaps.
- Codex token usage by model for the last 30 days, split into input, output, and cache tokens.
- Automatic refresh, stale-data handling, independent usage thresholds, and reset-expiry notifications.
- Adaptive popover height, capped at two thirds of the current screen before scrolling.
- Agent picker in the main panel with separate Accounts and General settings tabs.
- GitHub Copilot personal billing usage, AI credits, and per-model breakdown when GitHub provides them.
- Spanish, Catalan, and English localization.
- Universal binary for Apple Silicon and Intel Macs.

## Privacy

AI Usage MB starts the official `codex app-server --stdio` process and uses its account APIs. Authentication lives in an isolated Codex home at:

```text
~/Library/Application Support/AI Usage MB/CodexHome
```

The app does not consume reset credits and does not read the credentials or databases of your main Codex installation. To calculate usage by model, it locally scans the JSONL session files under `CODEX_HOME` or `~/.codex` and processes only model identifiers and token counters; prompt and response contents are neither stored nor transmitted. Existing data from the previous Codex Usage Bar name is migrated automatically.

GitHub Copilot uses GitHub's device authorization flow. The GitHub App asks only for read access to the account plan, never repository access, and stores its user token in the macOS Keychain. Personal usage endpoints do not include usage billed through an organization or enterprise; unavailable sections are omitted from the panel.

## Requirements

- macOS 14 Sonoma or later.
- Codex CLI installed and available as `codex` when using the Codex agent.
- A GitHub account when using GitHub Copilot.
- Xcode 15 or later to build from source.

## Install

### Homebrew

```bash
brew install --cask olerida/tap/aiusage
```

### Direct download

Download the latest signed ZIP from [GitHub Releases](https://github.com/olerida/AIusage/releases/latest), extract it, and move `AI Usage MB.app` to Applications.

## Build and test

```bash
swift test
swift run AIusage
```

Create a universal `.app` and ZIP:

```bash
./Scripts/package_app.sh
```

To sign during packaging:

```bash
APPLE_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./Scripts/package_app.sh
```

For Developer ID signing and notarization, configure an Apple notarytool keychain profile and run:

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_NOTARY_PROFILE="your-profile" \
  ./Scripts/sign_and_notarize.sh
```

Artifacts are written to `dist/AI Usage MB.app` and `dist/AIusage-macos-universal.zip`.

## Project structure

```text
Sources/AIusage/          SwiftUI app, Codex integration, models, and views
Tests/AIusageTests/       Usage and reset normalization tests
Resources/               Info.plist and production app-icon assets
Scripts/                 Packaging, signing, and notarization helpers
.github/workflows/       Automated test and release workflow
```

## Release

The current release is **v1.4.1**. Version tags matching `v*` run the test suite, build the universal app, and publish the ZIP through GitHub Actions. The Homebrew cask is maintained separately in `~/Documents/homebrew-tap`.

## License

AI Usage MB is available under the [MIT License](LICENSE).
