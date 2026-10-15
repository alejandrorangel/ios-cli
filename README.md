# ios-cli

An `ios` command-line tool for iOS development, for people and AI agents — the iOS counterpart of Google's [Android CLI](https://developer.android.com/tools/agents). See [PLAN.md](PLAN.md) for the feasibility study, findings and roadmap.

## Status

Skeleton (Phase 2 start). Working commands:

| Command | What it does |
|---|---|
| `ios info` | Active Xcode, booted simulators, connected devices |
| `ios sim list [--booted]` | Available simulators |
| `ios device list` | Paired physical devices (reads `devicectl` JSON v5, falls back to older fields) |
| `ios screen capture [--device <udid\|name>] [-o file.png]` | Screenshot of a simulator or device |
| `ios describe [--scheme S] [--device D]` | Schemes; with a scheme, the apps it builds (bundle ID, product path). Cached until project files change |
| `ios build --scheme S [--device D \| --platform simulator\|device]` | Builds and summarizes errors/warnings (file, line, column); full log saved to a file; exits non-zero on failure |
| `ios run --scheme S [--device D] [--no-build]` | Build, boot the simulator if needed, install, launch (restarting the app); reports the PID |
| `ios install <path.app> [--device D] [--launch]` | Install an app bundle (bundle ID read from its Info.plist) |
| `ios logs --bundle-id B [--device D] [--last 5m \| --launch] [--duration N]` | App logs. Simulator: follow or show the unified log. `--launch`: relaunch with the console attached (captures `print()`; required on devices, where the unified log needs root). `--json` prints NDJSON |

| `ios docs search <words> [--framework F] [--kind K]` | Searches all of Apple's documentation (363k pages). The first search downloads and indexes the catalog (~20 s) |
| `ios docs fetch <doc://…\|path\|URL>` | A documentation page as markdown, with `doc://` links to follow; cached 7 days |
| `ios docs api <Module.Symbol>` | Declaration, availability and doc comment from the installed SDK (offline; a module is extracted on first use, ~3–12 s) |
| `ios docs update` | Rebuild the search index |
| `ios layout [--bundle-id B] [--device D] [--full]` | Visible elements with type, identifier, label, value, state and tap point |
| `ios layout --swiftui [--relaunch]` | The app's SwiftUI view tree (its own views + stacks, lists, Text with its string…). `--relaunch` restarts the app with SwiftUI's debug data on; navigate with `ios input`, then read again. Debug builds only |
| `ios input tap --id I \| --label L \| <x> <y>` | Tap an element (or point); also `doubletap`, `swipe <x1 y1 x2 y2> \| --direction up`, `type <text>`, `button home` |
| `ios runner status \| stop [--device D]` | The UI automation runner behind `layout` and `input` |

| `ios preview <File.swift> [--index N] [--variant "Color Scheme=Dark Appearance"] [--locale fr] [-o out.png]` | Renders a SwiftUI `#Preview` to PNG through Xcode (first render builds, ~20 s; then ~0.5 s); lists available variants and locales |
| `ios create <Name> [--template app\|ios-app\|document-app\|game\|framework\|<id>] [--storage swiftdata] [--testing swift-testing] [--org com.example]` | New project from Xcode's own templates; `--list-templates` shows them with options |

Every command accepts `--json`. The planned `skills` command exists and reports its phase in PLAN.md.

`preview`, `create` and `--list-templates` use Xcode 27's tool service (`xcrun mcpbridge`; no Xcode window needed). Xcode asks you once to approve `ios` when a command first opens or creates a project (in testing, the approval carried over to rebuilt and installed binaries).

### UI automation (`layout`, `input`)

The first `layout`/`input` on a target builds a small XCUITest runner (cached per Xcode build) and starts it in the background; later commands reuse it (~0.4–1 s each). `--bundle-id` selects the app, and the last one is remembered per target. Stopping the runner (`ios runner stop`) also closes the app it was driving.

Physical devices need **Settings → Developer → Enable UI Automation** and a development team for signing: `--team`, `IOS_CLI_TEAM`, or detected automatically from a local wildcard development profile that includes the device. Nothing is changed in the developer account unless you pass `--allow-provisioning-updates`.

Docs data lives in `~/Library/Caches/ios-cli/docs` (override with `IOS_CLI_DOCS_DIR`): the search index (~125 MB), cached pages, and a symbol database per Xcode build.

Project commands look for a `.xcworkspace`, then `.xcodeproj`, then `Package.swift` in the current directory (override with `--workspace` / `--project`). Builds use Xcode's DerivedData by default, so they share Xcode's build cache; pass `--derived-data-path` to isolate them.

`--device` takes a UDID or name. Without it, the only booted simulator or connected device is used.

## Build and run

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
| `spikes/` | Feasibility prototypes and evidence (see `spikes/README.md`) |
