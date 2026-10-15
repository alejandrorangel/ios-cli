# ios-cli

An `ios` command-line tool for iOS development, for people and AI agents — the iOS counterpart of Google's [Android CLI](https://developer.android.com/tools/agents). See [PLAN.md](PLAN.md) for the feasibility study, findings and roadmap.

## Install

### Requirements

- A Mac with Apple silicon, running macOS 27
- Xcode 27, selected as the active developer directory (`xcode-select -p` should print `/Applications/Xcode.app/Contents/Developer`; if not, run `sudo xcode-select -s /Applications/Xcode.app`)

### One-line install (no compiling)

```sh
curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh -s -- --skill
```

This downloads the prebuilt binary from the latest [release](https://github.com/alejandrorangel/ios-cli/releases), verifies its checksum, installs it to `~/.local/share/ios-cli` with `ios` linked into `~/.local/bin`, and (because of `--skill`) installs the agent skill into `~/.claude/skills` so Claude Code sessions know how to use it. Leave out `-s -- --skill` to install only the command.

If your shell says `ios: command not found` afterwards, add `~/.local/bin` to your PATH:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### Check that it works

```sh
ios --version   # prints the installed version
ios info        # shows your Xcode, booted simulators and connected devices
```

### Update

Run the install command again; it replaces the binary with the latest release. Then refresh the skills: `ios skills update`.

A specific version: `curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh -s -- --version 0.2.0`.

### Uninstall

```sh
ios skills remove ios-cli                         # the agent skill (needs ios, so first)
rm -rf ~/.local/share/ios-cli ~/.local/bin/ios     # the command
rm -rf ~/Library/Caches/ios-cli                   # caches: docs index, runner builds, logs
```

### First use: things that ask for permission

- **UI automation on a physical device** (`ios layout`, `ios input`): turn on **Settings → Developer → Enable UI Automation** on the device and keep it unlocked. The runner is signed with your development team, detected from your Xcode provisioning profiles (or pass `--team <TEAM_ID>`).
- **Previews and new projects** (`ios preview`, `ios create`): the first time, Xcode shows a dialog asking to allow `ios` to use its tools. Click allow.

### From source

Requires the same Xcode 27. Clone the repository, then `scripts/install.sh --skill` builds a release and installs it the same way. See [Building from source](#building-from-source).

## Commands

All planned commands work. Every command accepts `--json` for machine-readable output, and `--device <udid|name>` where a target is needed (default: the only booted simulator or connected device).

### Environment

| Command | What it does |
|---|---|
| `ios info` | Active Xcode, booted simulators, connected devices |
| `ios sim list [--booted]` | Available simulators |
| `ios device list` | Paired physical devices (reads `devicectl` JSON v5, falls back to older fields) |
| `ios screen capture [-o file.png]` | Screenshot of a simulator or device |

### Build and run

| Command | What it does |
|---|---|
| `ios describe [--scheme S]` | Schemes; with a scheme, the apps it builds (bundle ID, product path). Cached until project files change |
| `ios build --scheme S [--platform simulator\|device]` | Builds and summarizes errors and warnings (file, line, column); full log saved to a file; exits non-zero on failure |
| `ios run --scheme S [--no-build]` | Build, boot the simulator if needed, install, launch (restarting the app); reports the PID |
| `ios install <path.app> [--launch]` | Install an app bundle (bundle ID read from its Info.plist) |
| `ios logs --bundle-id B [--last 5m] [--launch] [--duration N]` | App logs. Simulator: follow or show the unified log. `--launch`: relaunch with the console attached (captures `print()`; required on devices, where the unified log needs root). `--json` prints NDJSON |

### UI inspection and input

| Command | What it does |
|---|---|
| `ios layout [--bundle-id B] [--full]` | Visible elements with type, identifier, label, value, state and tap point |
| `ios layout --swiftui [--relaunch]` | The app's SwiftUI view tree (its own views, stacks, lists, `Text` with its string). `--relaunch` restarts the app with SwiftUI's debug data on; navigate with `ios input`, then read again. Debug builds only |
| `ios input tap --id I` / `--label L` / `<x> <y>` | Tap an element or a point |
| `ios input doubletap …`, `swipe <x1 y1 x2 y2>`, `swipe --direction up`, `type <text>`, `button home` | Other input |
| `ios runner status`, `ios runner stop` | The UI automation runner behind `layout` and `input` |

### Xcode: previews and new projects

| Command | What it does |
|---|---|
| `ios preview <File.swift> [--index N] [--variant "Color Scheme=Dark Appearance"] [--locale fr] [-o out.png]` | Renders a SwiftUI `#Preview` to PNG through Xcode (first render builds, ~20 s; then ~0.5 s); lists available variants and locales |
| `ios create <Name> [--template app] [--storage swiftdata] [--testing swift-testing] [--org com.example]` | New project from Xcode's own templates (`app`, `ios-app`, `document-app`, `game`, `framework` or any identifier); `--list-templates` shows them with their options |

### Documentation

| Command | What it does |
|---|---|
| `ios docs search <words> [--framework F] [--kind K] [--hig]` | Searches Apple's documentation (about 383k pages: frameworks, REST/JS web services, sample code, release notes) and the Human Interface Guidelines (172 pages; `--hig` for those only). The first search builds the index (~30 s) |
| `ios docs fetch <doc://…, hig://…, path or URL>` | A documentation or HIG page as markdown, with `doc://` / `hig://` links to follow; cached 7 days |
| `ios docs api <Module.Symbol>` | Declaration, availability and doc comment from the installed SDK (offline; a module is extracted on first use, ~3–12 s) |
| `ios docs update` | Rebuild the search index |

### Agent skills

| Command | What it does |
|---|---|
| `ios skills list` | The bundled `ios-cli` skill and Xcode 27's own (`swiftui-specialist`, `uikit-app-modernization`, …), with install state |
| `ios skills add <names>` / `--all`, `ios skills remove <names>`, `ios skills update` | Install into `~/.claude/skills` (`--project` for `./.claude/skills`, `--dir` for another folder) |

`preview`, `create` and `--list-templates` use Xcode 27's tool service (`xcrun mcpbridge`; no Xcode window needed). Xcode asks you once to approve `ios` when a command first opens or creates a project (in testing, the approval carried over to rebuilt and installed binaries).

### UI automation (`layout`, `input`)

The first `layout`/`input` on a target builds a small XCUITest runner (cached per Xcode build) and starts it in the background; later commands reuse it (~0.4–1 s each). `--bundle-id` selects the app, and the last one is remembered per target. Stopping the runner (`ios runner stop`) also closes the app it was driving.

Physical devices need **Settings → Developer → Enable UI Automation** and a development team for signing: `--team`, `IOS_CLI_TEAM`, or detected automatically from a local wildcard development profile that includes the device. Nothing is changed in the developer account unless you pass `--allow-provisioning-updates`.

Docs data lives in `~/Library/Caches/ios-cli/docs` (override with `IOS_CLI_DOCS_DIR`): the search index (~130 MB), cached pages, and a symbol database per Xcode build.

Project commands look for a `.xcworkspace`, then `.xcodeproj`, then `Package.swift` in the current directory (override with `--workspace` / `--project`). Builds use Xcode's DerivedData by default, so they share Xcode's build cache; pass `--derived-data-path` to isolate them.

`--device` takes a UDID or name. Without it, the only booted simulator or connected device is used.

## Building from source

Requires Xcode 27 (Swift 6) on macOS 14+.

```sh
swift build
swift run ios info
swift run ios sim list --booted --json
swift test
```

## Layout

| Path | Contents |
|---|---|
| `Sources/ios/` | Command definitions (swift-argument-parser) |
| `Sources/IOSCore/` | Logic: tool runner, `simctl`/`devicectl` parsing, target resolution, output |
| `Tests/IOSCoreTests/` | Parsing and resolution tests using sanitized samples (no device needed) |
| `Sources/IOSCore/Resources/` | The XCUITest runner project and the `ios-cli` agent skill, shipped with the binary |
| `spikes/` | Small reference prototypes (see `spikes/README.md`) |
