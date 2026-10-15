---
name: ios-cli
description: Builds, runs and inspects iOS apps from the terminal with the `ios` command — simulators and physical devices, build errors, app logs, screen layout and taps, SwiftUI view trees, and Apple documentation/API lookup. Use for any iOS or Xcode project work that needs building, running, verifying UI changes on a simulator or device, reading logs, or checking Apple APIs.
---
# iOS CLI

`ios` wraps Xcode's tools (`xcodebuild`, `simctl`, `devicectl`, XCUITest, LLDB) behind one command with JSON output. Use it to close the loop on iOS work: build → run → look at the screen → interact → verify.

## Installation

If `ios` isn't on the PATH, install it from the ios-cli repository: `scripts/install.sh` (installs to `~/.local/bin/ios`). Requires Xcode 27. Keep this skill current with `ios skills update`.

## Rules of thumb

- **Pass `--json`** when you'll parse the output. Text output is for people and may change.
- **Pass `--device <udid|name>`** when more than one simulator/device is active; without it the only booted simulator or connected device is used, and the error lists candidates otherwise.
- **Run project commands from the directory with the `.xcworkspace` / `.xcodeproj`** (or pass `--workspace` / `--project`). Pass `--scheme` when there's more than one; the error lists them.
- **Bound anything that streams**: `ios logs … --duration 10`.
- **Verify Apple APIs before using them**: `ios docs api Module.Symbol` reads the installed SDK, so it's authoritative for the Xcode in use (including iOS 27 APIs newer than your training data).

## Environment

- `ios info` — active Xcode, booted simulators, connected devices.
- `ios sim list [--booted]`, `ios device list` — targets with UDIDs.

## Simulator and app state

Simulator commands use `--device`, else the only booted simulator. Use them to set up a test state instead of tapping through Settings.

- `ios sim boot` (no `--device`: default iPhone), `ios sim shutdown`, `ios sim create <Name> --type "iPhone 17 Pro" --boot`, `ios sim delete --device D`.
- `ios sim erase` — wipe all apps, data and permissions (reboots a booted simulator). The only way to reset notification permission.
- `ios sim privacy reset <service> [--bundle-id B]` — make a permission prompt appear again (photos, location, microphone, contacts, calendar…); `grant`/`revoke` skip the prompt.
- `ios sim appearance dark|light`, `ios sim content-size accessibility-large` — check dark mode and Dynamic Type layouts.
- `ios sim location 37.3349,-122.0090` / `clear`; `ios sim push --bundle-id B --title T --body "…"` (needs notification permission); `ios sim status-bar --clean` before screenshots.
- `ios app open-url myapp://path` — test deep links and universal links (simulator or device).
- `ios app list`, `ios app launch|terminate|uninstall --bundle-id B` — simulator or device. `ios screen record --duration 5 -o clip.mp4` (simulator).

## Build and run

- `ios describe [--scheme S]` — schemes; with a scheme, the apps it builds (bundle ID, product path). Cached until project files change.
- `ios check <File.swift> [more files]` — errors and warnings for just those files, ~0.3 s, no build (`--json`: `diagnostics` with line, no column). Run it right after editing; then `ios build` before running. Needs Xcode's one-time approval of `ios`.
- `ios build --scheme S [--device D]` — builds and prints errors with file:line:column (`--json`: structured `errors`); exits non-zero on failure; full log path in the output.
- `ios run --scheme S --device D` — build, boot the simulator if needed, install, launch; prints the PID. `--no-build` reinstalls the last build.
- `ios test --scheme S [--device D]` — runs the scheme's tests; prints passed/failed/skipped counts and each failure as `file:line: message` (`--json`: `failures[].failures[]`). Without --device it uses the booted simulator, else an iPhone simulator (never a physical device). Rerun one test with `--only <id>` using the id it printed (Target/Suite/test; XCTest ids drop the `()`, Swift Testing ids keep them); add `--no-build` when only test data changed. Build errors come back as `buildErrors`. Exits non-zero on failure.
- `ios install <path.app> [--launch]` — install an app bundle.
- **Signing on a physical device**: if a build fails with "requires a development team" (e.g. a project from `ios create`), the output has a `hint`. Ask the user which team should own the app, then pass `--team <TEAM_ID>` to `ios build|run|test`; it applies to that build only and may register the bundle ID in that team. Never pick a team from local profiles for an app yourself — they may belong to the user's employer.

## Logs

- `ios logs --bundle-id B --device D --last 2m` — recent unified log (simulator).
- `ios logs --bundle-id B --device D --duration 10` — follow the unified log (simulator).
- `ios logs --bundle-id B --device D --launch --duration 15` — relaunch with the console attached; also captures `print()`. **Required on physical devices** (their unified log needs root).

## Screen, layout and input

- `ios screen capture --device D -o shot.png` — screenshot.
- `ios layout --bundle-id B --device D` — visible elements: `[n] Type id=… "label" value=… @(x,y)`. The last app is remembered per device. A system alert (e.g. a permission prompt) is listed last with its buttons, and the app's elements are marked `covered`; tap `--label Allow` to answer it.
- `ios input tap --id <identifier>` (best) / `--label <text>` / `<x> <y>` — taps the element's visible centre.
- `ios input type <text> [--submit]` — types into the focused field; tap the field first (an unfocused `type` fails with a clear error). `--submit` presses Return afterwards. `ios input key delete --count 20` clears text; `key return|tab|space` too.
- `ios input wait --id X [--timeout 10]` — after a tap that loads something, wait for the next screen's element instead of sleeping or retrying; `--gone` waits for a spinner to disappear. Exits non-zero on timeout.
- `ios input scroll-to --id X` (or `--label`, exact) — scrolls until the element is on screen, then `ios input tap --id X`. In lazy lists rows don't exist until shown, so it scrolls down and then back up; pass `--direction down` when you know it's above.
- `ios input swipe --direction up|down|left|right`, `ios input doubletap …`, `ios input button home`.
- `ios runner status|stop --device D` — the XCUITest runner behind layout/input. It starts on first use (~15 s, built once per Xcode) and then answers in ~0.5–1 s. Stopping it closes the app it was driving.

Typical verification loop after a UI change:
```
ios run --scheme MyApp --device "iPhone 17"
ios layout --bundle-id com.example.MyApp        # find identifiers
ios input tap --id loginButton
ios layout                                      # confirm the new screen / values
ios logs --bundle-id com.example.MyApp --last 1m
```
If `layout` comes back empty right after a launch, the app is still loading — run it again.

`ios layout` lists XCUITest's automation elements, which include views hidden from VoiceOver (e.g. `.accessibilityHidden(true)`). To check accessibility, use `ios layout --voiceover` (iOS 27+): it walks the screen with VoiceOver and lists what it speaks, in order. It takes a few seconds per screen and switches VoiceOver back off afterwards. If a system alert (Low Battery, a permission prompt) is showing, VoiceOver reads it instead: those items are marked `(system alert)` and a warning follows — dismiss the alert and walk again. Elements marked `covered` in `ios layout` sit under a full-screen presentation; tap what's on top.

Physical devices need **Settings → Developer → Enable UI Automation**, and the runner is signed with the team's development profile (auto-detected from a local wildcard profile, or `--team <TEAM_ID>`).

## SwiftUI view tree

- `ios layout --swiftui --relaunch --bundle-id B --device D` — restart the app with SwiftUI's debug data and print its view tree (the app's own views plus stacks, lists, `Text` with its string). Debug builds only.
- Then navigate with `ios input …` and run `ios layout --swiftui` (no `--relaunch`) to read the current screen. `ios run` relaunches without the data.
- Use it to find which view produces an element when fixing layout bugs. UIKit screens don't appear.

## Documentation

- `ios docs search "core bluetooth scan" [--framework swiftui] [--kind method]` — all Apple docs plus the Human Interface Guidelines (first run builds the index, ~30 s). Results are `doc://…` (API docs) or `hig://…` (guidelines) paths.
- `ios docs search sliders --hig` — only the Human Interface Guidelines. Check the relevant guideline (controls, dark mode, accessibility, app icons, platform conventions) when designing or reviewing UI.
- `--source tutorials|swift-book|app-review|wwdc|api` limits a search to Apple's tutorials, the Swift book, the App Store Review Guidelines, WWDC sessions, or API docs only.
- `ios docs fetch asrg://5.1.1` — a Review Guideline (check before adding purchases, sign-in, data collection, user-generated content…); `asrg://` lists them all.
- `ios docs fetch wwdc://2026/258` — a WWDC session's description and full timestamped transcript (find sessions with `--source wwdc`); `tutorial://…` pages include each step's code.
- `ios docs fetch doc://swiftui/navigationstack` / `ios docs fetch hig://sliders` — a page as markdown, with `doc://` / `hig://` links to follow (HIG pages link to the matching APIs, e.g. `doc://swiftui/slider`).
- `ios docs api SwiftUI.View.navigationDestination` — declaration, availability and doc comment from the installed SDK (first use of a module takes ~3–12 s). Objective-C-based modules (UIKit, AVFoundation) have declarations but little prose; use `docs fetch` for those.

## SwiftUI previews

- `ios preview Path/To/View.swift [--name "Dark mode" | --index N] [-o view.png]` — renders one of the file's previews to a PNG through Xcode: by name (`#Preview("Dark mode")` or a `PreviewProvider` type; exact, else contains) or position (0 = first). `ios preview Path/To/View.swift --list` lists the file's previews instantly. First render builds the project (~20 s+), then ~0.5 s. Look at the PNG to check a UI change without running the app.
- The output lists available variants and locales; pass them back: `--variant "Color Scheme=Dark Appearance" --variant "Dynamic Type=AX 5"`, `--locale fr`. Use this to check dark mode, large text and localizations.
- Run from the project directory (or pass `--workspace` / `--project`).

## New projects

- `ios create MyApp [--template app|ios-app|document-app|game|framework] [--storage swiftdata|coredata] [--testing swift-testing|xctest] [--org com.example] [-o dir]` — uses Xcode's own templates. Xcode 27's `app` template is multiplatform; `ios-app` is iPhone/iPad only.
- `ios create --list-templates [--platform ios]` — templates and their options (`--option key=value` for others).

`preview` and `create` go through Xcode's tool service: the first time, Xcode shows a dialog to approve `ios` — ask the user to approve it if a command reports "hasn't approved".

## Skills

- `ios skills list` — the bundled `ios-cli` skill and the skills that ship with Xcode 27 (`swiftui-specialist`, `swiftui-whats-new-27`, `uikit-app-modernization`, `app-intents-specialist`, `modernize-tests`, …), with install state.
- `ios skills add <names…>` / `--all`, `ios skills remove <names…>`, `ios skills update` — into `~/.claude/skills` (`--project` for `./.claude/skills`, `--dir` for another agent's folder). Only skills installed by `ios skills` are updated or removed.
