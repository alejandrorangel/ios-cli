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
ios doctor      # checks Xcode, simulators, devices, signing, Xcode approval, docs and skills, with fixes
ios info        # shows your Xcode, booted simulators and connected devices
```

### Update

`ios update` replaces the installed binary with the latest release (`--check` only reports; the download's checksum is verified). With `IOS_CLI_SIGN_IDENTITY` set to a signing certificate's SHA-1 or name, the new binary is signed, so Xcode keeps its approval of `ios`. Running the install command again works too. Then refresh the skills: `ios skills update`.

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
| `ios doctor [--offline] [--skip-xcode-service]` | Read-only health check of everything ios-cli needs (Xcode and its first-launch setup, simulator runtimes, Developer Mode, signing, Xcode's approval of `ios`, docs index, skills, PATH, newer release), each problem with its fix. Exits non-zero only on blocking problems |
| `ios sim list [--booted]` | Available simulators |
| `ios device list` | Paired physical devices and their state as `devicectl` shows it (`connected`, `available (paired)`, `unavailable`) |
| `ios screen capture [-o file.png] [--annotate]` | Screenshot of a simulator or device. `--annotate` numbers each element `ios layout` lists, with the same `[N]`, and prints the list |
| `ios screen resolve --screenshot shot.png "#N"` | Replaces each `#N` with that element's tap point, saved in the annotated PNG: `ios input tap $(ios screen resolve --screenshot shot.png "#12")` |
| `ios screen record [--duration 10] [-o file.mp4]` | Records a simulator's screen (H.264), timed from the first frame |

### Simulators and apps

Simulator commands act on `--device` (name or UDID), else the only booted simulator.

| Command | What it does |
|---|---|
| `ios sim create <Name> [--type "iPhone 17 Pro"] [--os 27.0] [--boot]` | New simulator (newest runtime by default) |
| `ios sim boot [--show]`, `ios sim shutdown [--all]` | Boot and wait until ready (no `--device`: the default iPhone on the newest iOS); shut down |
| `ios sim erase`, `ios sim delete --device D` | Erase all content and settings (a booted simulator is rebooted); delete |
| `ios sim appearance [light\|dark]`, `ios sim content-size [size\|increment\|decrement]` | Dark mode and Dynamic Type; without a value, prints the current one |
| `ios sim location <lat,lon>\|clear` | Simulated location |
| `ios sim privacy grant\|revoke\|reset <service> [--bundle-id B]` | Permissions (photos, location, microphone, contacts…); `reset` makes the app prompt again |
| `ios sim push --bundle-id B (--title T --body … \| payload.json)` | Simulated push notification |
| `ios sim status-bar --clean [--battery 42 …] \| --clear` | Status bar overrides for screenshots (9:41, full battery and signal) |
| `ios app list [--all]` | Installed apps (simulator or device; yours unless `--all`) |
| `ios app launch\|terminate\|uninstall --bundle-id B` | App control on a simulator or device. `launch` takes `--launch-env NAME=VALUE` and app arguments after `--` |
| `ios app open-url <url>` | Open a deep link or universal link as if tapped |

### Build and run

| Command | What it does |
|---|---|
| `ios describe [--scheme S]` | Schemes; with a scheme, the apps it builds (bundle ID, product path). Cached until project files change |
| `ios build --scheme S [--platform simulator\|device] [--team ID]` | Builds and summarizes errors and warnings (file, line, column); full log saved to a file; exits non-zero on failure. Signing failures come with a hint |
| `ios run --scheme S [--no-build] [--team ID] [--wait-for-device N] [--launch-env NAME=VALUE] [-- app arguments]` | Build, boot the simulator if needed, install, launch (restarting the app); reports the PID. Arguments after `--` reach the app (`-- -Flag YES` sets that UserDefaults key for the launch). A paired device that's locked or out of reach is reported before building; `--wait-for-device` waits for it |
| `ios test --scheme S [--team ID] [--only T/Suite/test] [--skip …] [--test-plan P] [--no-build] [--retries N] [--env NAME=VALUE] [--no-parallel] [--attachments DIR] [--show-output] [--timeout S]` | Runs unit and UI tests (`--env` sets a variable in the test process; `--no-parallel` runs one suite at a time and the output names suites that overlapped); lists attachments, with the text of small ones, from passing tests too; shows what each failed test printed (`--show-output`: every test); one run per simulator or device at a time; stops xcodebuild when the test host fails to launch or xcodebuild hangs after the tests, and names the test that was running when a host crashed; lists each failure with file:line and an id to pass back to `--only`; saves the log and `.xcresult`; exits non-zero on failure |
| `ios install <path.app> [--launch]` | Install an app bundle (bundle ID read from its Info.plist) |
| `ios logs --bundle-id B [--last 5m] [--launch] [--duration N]` | App logs. Simulator: follow or show the unified log. `--launch`: relaunch with the console attached (captures `print()`; required on devices, where the unified log needs root). `--json` prints NDJSON |

**Signing for devices.** `ios build`, `run` and `test` use the project's signing settings. A project without a team (for example one from `ios create`) needs `--team <TEAM_ID>` for a physical device: it's applied to that build only, with automatic signing, so Xcode may register the app's bundle ID in that team. ios-cli never picks a team for an app. The UI automation runner is different: with no `--team` it uses the one team that has a local wildcard development profile for the device, says which, and changes nothing in that account.

### UI inspection and input

| Command | What it does |
|---|---|
| `ios layout [--bundle-id B] [--full]` | Visible elements with type, identifier, label, value, state and tap point. A system alert (permission prompt) is listed on top, with the app's elements marked `covered` |
| `ios layout --voiceover [--max N]` | What VoiceOver reads on the screen, in its navigation order (iOS 27+, via `XCUIVoiceOverService`). Unlike the element list, views hidden from accessibility don't appear, so use it to check accessibility. Items read from a system alert (Low Battery, permission prompts) are flagged. VoiceOver is switched back off afterwards |
| `ios layout --swiftui [--relaunch]` | The app's SwiftUI view tree (its own views, stacks, lists, `Text` with its string). `--relaunch` restarts the app with SwiftUI's debug data on; navigate with `ios input`, then read again. Debug builds only |
| `ios layout -o FILE` | Write the layout (text, or JSON with `--json`) to a file |
| `ios input tap --id I` / `--label L` / `--index N` / `<x> <y>` | Tap an element (`--index`: its `[N]` from `ios layout` or an annotated screenshot) or a point |
| `ios input drag --label L --to <x> <y>` / `--to-label L2` / `--to-id` / `--to-index` | Press and hold, drag, hold, release: handles, sliders, reordering (`--hold`, `--end-hold` set the pauses) |
| `ios input type <text> [--submit]`, `ios input key return\|delete\|tab\|space [--count N]` | Type into the focused field; `--submit` presses Return after |
| `ios input wait --id I [--gone] [--timeout 10]` | Wait until an element is visible (or gone, e.g. a spinner) instead of retrying |
| `ios input scroll-to --id I` / `--label L` | Scroll until the element is on screen (toward it if it exists off screen; lazy lists: down, then back up) |
| `ios input doubletap …`, `swipe <x1 y1 x2 y2>`, `swipe --direction up [--label L]`, `button home` | Other input; `swipe --direction` with `--id`/`--label`/`--index` stays inside that element (a carousel, one list among several) |
| `ios runner status`, `ios runner stop` | The UI automation runner behind `layout` and `input` |

### Xcode: checks, previews and new projects

| Command | What it does |
|---|---|
| `ios check <File.swift>…` | Compiler errors and warnings for the given files without a full build, through Xcode (~0.3 s warm; the first call starts Xcode's service, ~2 s). Exits non-zero on errors |
| `ios preview <File.swift> [--name N \| --index N] [--variant "Color Scheme=Dark Appearance"] [--locale fr] [--scheme S] [-o out.png]` | Renders a SwiftUI `#Preview` to PNG through Xcode (first render builds, ~20 s; then ~0.5 s); lists available variants and locales. Pick the preview by name (`#Preview("Dark mode")` or a `PreviewProvider`) or position; `--list` shows a file's previews without rendering. Xcode hosts a preview in the active scheme's product: `--scheme` makes the library's or app's scheme active first (it stays active, as in Xcode's toolbar) |
| `ios xcode tools`, `ios xcode call <Tool> [--arg name=value] [--args '{json}']` | List Xcode's tools and call any of them with the project in the current folder (`GetTestList`, `XcodeGrep`, `GetTargetBuildSettings`, `RunCodeSnippet`…) |
| `ios create <Name> [--template app] [--storage swiftdata] [--testing swift-testing] [--org com.example]` | New project from Xcode's own templates (`app`, `ios-app`, `document-app`, `game`, `framework` or any identifier); `--list-templates` shows them with their options |

### Diagnostics: app size, crashes, profiling

| Command | What it does |
|---|---|
| `ios analyze <App.app\|.ipa\|.xcarchive>` | What's in a build: bundle ID, version, minimum iOS, architectures; size by part (executable, frameworks, extensions, asset catalogs, resource bundles) and the largest files; signing kind, profile and entitlements; privacy manifests. Notes flag Debug/simulator builds, expired profiles and frameworks without a privacy manifest |
| `ios crashes [--bundle-id B] [--hours 72]`, `ios crashes show <file.ips>` | Crash reports from a simulator (`~/Library/Logs/DiagnosticReports`) or device (copied off it and cached); `show` prints the exception, the reason (`Fatal error: …`) and the crashed thread, symbolicating the app's frames with its dSYM (found by UUID) or the local binary |
| `ios profile --app App.app \| --bundle-id B \| --attach P [--seconds 10] [--template "Time Profiler"] [-o profile.trace]` | Records an Instruments trace with `xctrace` and summarizes it: CPU per thread, the heaviest functions in the app's own code (total and self time) and overall. `--app`/`--bundle-id` launch the app under the profiler; attaching to a simulator process needs `sudo DevToolsSecurity -enable` once. Other templates are recorded and their tables listed |
| `ios signals crashes [--bundle-id B] [--app-version V] [--beta\|--app-store]`, `ios signals crash "<signature>"` | Top crash signatures your users hit (last 14 days), and one signature's logs with triage notes, from Apple's crash reports through Xcode (sign in to your developer account in Xcode; the app must be in the Organizer) |
| `ios signals performance --type launches\|hangs\|diskwrites\|energy`, `ios signals performance-issue` | Field performance issues, the same way |

### Journeys

A journey is a user flow written as plain-language steps in a `*.journey.xml` file, in the Android CLI's journey format (`<journey name>`, `<description>`, `<actions><action>…`), so one file can describe a flow for both apps. An agent carries out the steps with `ios layout`, `ios input` and `ios screen`; the `ios-cli` skill has the rules. ios-cli adds an optional `<setup platform="ios">` that Android ignores:

```xml
<setup platform="ios">
  <launch bundle-id="com.example.app">
    <argument>-SkipOnboarding</argument><argument>YES</argument>
    <env name="API_ENV" value="staging"/>
  </launch>
  <open-url>example://practice/42</open-url>
</setup>
```

| Command | What it does |
|---|---|
| `ios journey list [dir]` | Journey files under a folder (skipping build output and dependencies), checked, with their step counts |
| `ios journey show F` | A journey's setup and numbered steps, checks (`Verify…`, `Check…`) marked |
| `ios journey setup F` | Relaunches the app with the setup's arguments and environment, then opens its URLs |
| `ios journey report result.json [-o report.md]` | Checks the agent's result JSON against the journey and writes the Markdown report (Android's layout); exits 1 unless it passed |

### Documentation

| Command | What it does |
|---|---|
| `ios docs search <words> [--source S] [--framework F] [--kind K]` | Searches about 384k pages: API docs (frameworks, REST/JS web services, sample code, release notes), the Human Interface Guidelines, Apple's tutorials, the Swift book, the App Store Review Guidelines and WWDC sessions (2023–2026). `--source api\|hig\|tutorials\|swift-book\|app-review\|wwdc` limits to one. iOS comes first: frameworks only on other platforms (AppKit, WatchKit, TVML…) rank lower unless named (`--framework appkit`, "appkit table view", `NSTableView`). The first search builds the index (under a minute) |
| `ios docs fetch <link or URL>` | A page as markdown: `doc://…` (API docs, Swift book), `hig://…`, `tutorial://…` (steps with code), `asrg://4.2` (a Review Guideline and its sub-items; `asrg://` for the contents), `wwdc://2026/258` (description and timestamped transcript), or the developer.apple.com / docs.swift.org URL |
| `ios docs api <Module.Symbol>` | Declaration, availability and doc comment from the installed SDK (offline; a module is extracted on first use, ~3–12 s). Includes the test frameworks that ship outside the SDK: `XCTest`, `XCUIAutomation`, `Testing` |
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

`ios check`, `preview` and `create` go through Xcode's tool service, which asks you to approve `ios`. An unsigned build is approved for 24 hours at most and asks again after every rebuild; a signed one is approved once. To sign what `scripts/install.sh` installs, set `IOS_CLI_SIGN_IDENTITY` to a code-signing certificate's SHA-1 or name (`security find-identity -v -p codesigning`), e.g. in your shell profile. Xcode also approves each project folder; approving a parent folder durably covers the projects in it.

## Layout

| Path | Contents |
|---|---|
| `Sources/ios/` | Command definitions (swift-argument-parser) |
| `Sources/IOSCore/` | Logic: tool runner, `simctl`/`devicectl` parsing, target resolution, output |
| `Tests/IOSCoreTests/` | Parsing and resolution tests using sanitized samples (no device needed) |
| `Sources/IOSCore/Resources/` | The XCUITest runner project and the `ios-cli` agent skill, shipped with the binary |
| `spikes/` | Small reference prototypes (see `spikes/README.md`) |
