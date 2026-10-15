# iOS CLI — Feasibility Plan

_Last updated: 2026-10-15 · Results were measured on a production SwiftUI/UIKit app ("the test app") · Environment tested: Xcode 27.0 (27A266a), macOS 27, iOS 27.0 & 26.5 simulators, iPad Pro 12.9" (5th gen) on iOS 26.5 → 27.0.1_

## Goal

Build an `ios` command-line tool that does for iOS development what Google's [Android CLI](https://developer.android.com/tools/agents) (`android`) does for Android: one consistent, JSON-friendly command surface for **humans and AI agents** covering environment setup, simulators/devices, build-and-run, screen inspection, UI input, IDE integration, documentation, and skills.

## TL;DR

**Feasible — every Android CLI capability except remote device reservations has a verified iOS path.**

- **Base layer (CI-safe, no Xcode GUI):** `xcodebuild` / `simctl` / `devicectl` / `swift package` cover `info`, `describe`, `build`, `install`, `run`, `sdk`, `screen capture`, logs. Verified end-to-end on the test app (clean build 84 s, launch 0.8 s).
- **UI tree + input:** two working backends.
  - **Xcode 27 MCP bridge** (`xcrun mcpbridge`) — tree + tap/swipe/type/buttons in < 1 s; requires **iOS 27+ simulators** (physical devices **not supported** in Xcode 27.0 — verified on an iOS 27.0.1 iPad) and one-time approval.
  - **Own XCUITest runner** (WebDriverAgent-style) — tree, tap, swipe, type and screenshots verified on the **iOS 26.5 simulator and a physical iPad (iOS 27.0.1)**; tree 0.1–0.7 s, input 0.6–2.3 s (idle-wait). **The only path for physical devices.**
- **IDE features:** bridge covers create, describe, build, previews (0.2–0.4 s warm), run, tests, diagnostics — served by a **background "Xcode Service"**, no Xcode window needed.
- **Docs:** full Apple doc index (363k pages, ~18 MB zstd) + offline SDK symbol graphs (~5 MB) + live DocC→markdown fetch. Prototype working.

Remaining unknowns are narrow: faster XCUITest input (idle-wait removal), find-usages without the bridge, and bridge behavior with Xcode fully quit / headless mode.

---

## 0. Value for agentic coding workflows

**Core benefit: agents can check their own work.** Today an agent editing an iOS app can change code and maybe compile it, but can't confirm the UI behaves correctly. `ios` gives it a full loop from the terminal: build, run, read the screen, interact, then verify. Without that, "done" means "it compiles", and a person still has to do the QA.

### Where it helps most

1. **Checking UI changes.** Build, launch, read the screen tree, tap through the flow, confirm the result. Verified on the test app: tap the search field, type a query, then confirm the typed `value` in the tree and the results on screen.
2. **Using APIs that actually exist.** Models often invent iOS APIs or use outdated signatures, especially for APIs newer than their training data (e.g. iOS 27). `ios docs api` reads signatures from the installed SDK and `ios docs fetch` returns Apple's page as markdown, so a wrong call is caught before the build fails.
3. **Fixing layout bugs from evidence.** `ios layout --swiftui` shows which view and modifier produced an element (e.g. `HomeView → LazyVStack → FeatureCard`), so the agent works from the real structure instead of guessing from a screenshot.
4. **Reproducing bugs, on real devices too.** The agent follows repro steps on a simulator or a physical device, captures logs (`log stream` as NDJSON) and screenshots, then verifies the fix the same way.
5. **Running without Xcode open.** Build, run, logs and docs work from any agent (Claude Code, Codex, Cursor) and in CI, with no MCP setup and no Xcode window.

### What Xcode 27 already provides, and the gaps `ios` fills

Xcode 27 already gives agents build, previews, run, tests and taps on iOS 27 simulators through its MCP bridge. For a team that only works inside Xcode on iOS 27 simulators, the added value is smaller. `ios` covers the gaps:

| Gap in Xcode 27's agent tools | What `ios` adds |
|---|---|
| Device interaction on simulators only, iOS 27+ only | Physical devices and older iOS versions (XCUITest runner) |
| Needs Xcode plus per-agent approval | Core commands work from any terminal and in CI |
| No documentation tools | Offline search, API lookup from the installed SDK, page fetch |
| No SwiftUI structure | `layout --swiftui` |
| MCP tools only | One CLI any agent can call, plus skills that teach agents how to use it |

### Costs to weigh

- **Latency:** a check loop (tap, then read the tree) takes about 1–3 s per step on a device; builds take 20–84 s. Fine for verification, too slow for long exploratory sessions.
- **Context size:** raw trees can be large (the SwiftUI dump was 2.3 MB), so commands need compact output (interactive elements only, filtered SwiftUI view, `--json` with selectable fields).
- **Upkeep:** the Xcode bridge and SwiftUI debug data are undocumented and may change with any Xcode release; re-check on each beta.

### How to measure it

Pilot on a real app: pick about 10 real tickets (UI tweaks, bug fixes, a new screen) and give an agent each one twice, with and without `ios`. Compare:
- how often the change works the first time,
- how many rounds of human feedback it needs,
- how often the agent used an API that doesn't exist.

The Phase 2 MVP (build, run, logs, docs) plus the existing `layout`/`input` spike code is enough for this pilot. Expected biggest wins: **UI verification** and **SDK-accurate docs**, where agents most often fail on iOS today.

---

## 1. Command mapping: `android` → `ios`

| `android` | `ios` backend(s) | Status | Evidence |
|---|---|---|---|
| `info` | `xcode-select -p`, `xcodebuild -version`, `simctl list -j`, `devicectl list devices -j -` | 🟢 | All JSON, < 1 s total (Spike C) |
| `emulator` | `simctl create/boot/shutdown/erase/clone/list` | 🟢 | Boot ≈ 25 s cold (Spike C) |
| `sdk` | `simctl runtime list -j` / `delete --outdated --dry-run`; `xcodebuild -showsdks -json`, `-downloadPlatform`, `-importPlatform`, `-downloadComponent` | 🟢 | Help + listings verified; nothing downloaded |
| `describe` | CI: `xcodebuild -list -json` (10 s), `-showBuildSettings -json` (8–42 s), `swift package describe` (0.6 s) — **cache needed**. Bridge: `XcodeListSchemes/Targets/RunDestinations`, `GetTargetBuildSettings` (≤ 0.04 s) | 🟢 | Spikes B, C |
| `install` | `simctl install` / `devicectl device install app` | 🟢 | 4.3 s sim (Spike C) |
| `run` | CI: `xcodebuild build` → install → `simctl launch` / `devicectl device process launch`. Bridge: `BuildProject` (2–4 s), `RunProject` (2.1 s), `DeviceInteractionInstallAndRun` | 🟢 sim / 🟡 device signing | the test app clean build 84 s, no-op 20 s, launch 0.8 s |
| `screen capture` | `simctl io screenshot`; `devicectl device capture screenshot` | 🟢 | iPad 2732×2048 in 1.6 s |
| `layout` | Bridge `DeviceInteractionSynthesize` (iOS 27+) → XCUITest runner (any iOS) → LLDB AX walk (sim, read-only) | 🟢 | §2 |
| `screen resolve` | Own implementation over `layout` + screenshot | 🟢 | Depends on `layout` |
| input | Bridge command language (iOS 27+) → XCUITest runner (any iOS) | 🟢 | §3 |
| `studio` | Bridge: `RenderPreview`, `XcodeRefreshCodeIssuesInFile`, `RunAllTests/RunSomeTests`, `GetConsoleOutput`, `InvokeDebuggerCommand`, `XcodeGrep`. CI: `sourcekit-lsp` + compile DB (definition ✅), `indexstore-db` (usages, untested) | 🟢 bridge / 🟡 CI | Spikes B, C |
| `create` | Bridge `XcodeListTemplates` (52 templates) + `XcodeNewProject` (1.7 s) | 🟢 | Spike B |
| `docs` | Prebuilt doc index + live DocC fetch + local symbol graphs | 🟢 | §4, Spike D |
| `skills` | `xcrun mcpbridge run-agent skills export` (9 Xcode skills) + our own | 🟢 | Exported successfully |
| logs (new) | `simctl spawn … log stream --style ndjson`; `simctl launch --console-pty` for `print()`; `devicectl … process launch --console`; bridge `GetConsoleOutput` | 🟢 | 1,577 NDJSON lines / 8 s (Spike C) |
| `device` (remote reservations) | No Apple equivalent | ⚪ Out of scope | — |
| `init`, `update`, `completion` | Pure CLI (`swift-argument-parser` completions) | 🟢 | — |

---

## 2. UI inspection (`layout`)

| Approach | Result | Verdict |
|---|---|---|
| `po [keyWindow recursiveDescription]` (LLDB) | SwiftUI renders as `CGDrawingLayer` / `SwiftUI.ImageLayer`: no text, buttons, identifiers. Only UIKit chrome readable. | ❌ |
| `SWIFTUI_PRINT_TREE=1` | Real but undocumented; prints the **render display list** (frames, `text`, `image`), not the structural view tree. Parent-relative frames, no identifiers/traits, re-dumps on every update, needs relaunch. | ❌ render debugging only |
| Xcode View Hierarchy Debugger protocol (R3) | Through LLDB: `dlopen("/usr/lib/libViewDebuggerSupport.dylib")`, then `DebugHierarchyRequest` + `DBGTargetHub performRequest:`. Returns gzipped JSON v2 (50 KB, 0.17 s) of UIWindow / view controllers / constraints / layers / scenes, but SwiftUI content still shows only as drawing layers. | ⚪ UIKit-level only |
| **SwiftUI view-debug tree** (R3) | Launch the app with `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=<bitmask>`, then call `-[_UIHostingView makeViewDebugData]` on each hosting view through LLDB. Returns the **real SwiftUI structure**, e.g. `WelcomeView → GeometryReader → ZStack → VStack → Spacer/Image/Color` with modifiers (`_PaddingLayout`, `_FlexFrameLayout`, `_OpacityEffect`). `=1` gives type + value (360 KB, 180 nodes on the test app's welcome screen); `=255` adds position, size, transform, environment and layout data (497 KB). Needs a debuggable build, a relaunch with the variable, and LLDB attach. Private SPI. **Verified on the physical iPad too** (R4): `devicectl device process launch --environment-variables '{"SWIFTUI_VIEW_DEBUG":"1"}'` → attach via LLDB's Python API in async mode (`device select <udid>` + `device process attach -p <pid>`; stopped after ~13 s) → dump written to the app's `tmp/` → `devicectl device copy from --domain-type appDataContainer`. Test app home screen: 41 + 910 nodes (189 KB + 2.3 MB), 17 s total, including the app's own view types (cards, rails, section headings, custom buttons). Output is dominated by SwiftUI internals (`ModifiedContent`, `StaticIf`, scroll/toolbar modifiers), so the CLI needs a filtered view (app-module types + layout containers). | 🟡 `ios layout --swiftui` (debug view, not for tapping) — sim + device |
| LLDB accessibility-tree walk | 48 elements with labels/ids/traits/frames in ≈ 3.8 s, **only after** enabling sim `ApplicationAccessibilityEnabled` + `AutomationEnabled`. System apps refuse attach. Device attach now works (see SwiftUI row: async attach, ~13 s), but the walk itself hasn't been re-run on a device. | 🟡 sim fallback |
| **XCUITest runner** (Spikes A, E) | Full SwiftUI tree (types, ids, labels, values, frames, focus/selected) in 0.05–0.14 s (JSON snapshot) / 0.3–0.7 s (`debugDescription`). Works on system apps (Settings). **No settings changes needed** on the simulator; on a device it needs *Settings → Developer → Enable UI Automation*. No hitPoints in `snapshot()` → compute visible frame centers. **Gaps:** the iPad's floating top tab bar (iOS 26+) is missing from the tree (only its title shows) → fall back to screenshot coordinates; a read right after launch or navigation shows the loading state → wait for idle or retry. | 🟢 sim + physical device |
| **Xcode bridge `DeviceInteractionSynthesize`** | Screenshot + thumbnail + hierarchy with **hitPoints** and multi-app `activationBundleId` + logs + app state, < 1 s. | 🟢 iOS 27+ |

Sample bridge hierarchy (test app welcome screen, iOS 27 sim; identifiers renamed):

```
Application, pid: 57341, label: 'App'
 Window, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
  ...
  Button, {{40.0, 697.0}, {322.0, 50.0}}, identifier: 'welcome-get-started-button', label: 'Get started', hitPoint: {201.0, 722.0}
  Button, {{39.0, 762.0}, {324.0, 52.0}}, identifier: 'welcome-sign-in-button', label: 'Sign In', hitPoint: {201.0, 788.0}
```

### Xcode 27 research on layout (R1 release notes, R2 SDK, R3 Xcode internals)

- **Apple confirms device interaction is simulator-only.** Release note 175179787: "Agents can now boot simulators, install and launch apps, synthesize touch events, and capture screenshots". No Apple source mentions physical devices. Xcode's GUI **Device Hub** can send pointer input to physical devices, but nothing public exposes it.
- **How the bridge does it:** XCUITest running **on the Mac host** against the simulator (`_XCUIEnableRemoteAutomationNoTests`, `XCUIRemoteDeviceManager`, private `Recap.framework` for the command language), so no runner app is installed on the device. It's private SPI and depends on Apple-private entitlements held by `Xcode Service.app` (`com.apple.dt.testmanagerd.control.client`, `com.apple.private.dt.xcode.set-responsible-process-for-ui-testing`, …), so **a third-party CLI can't reuse it directly**.
- **XCTest in iOS 27:** the only new UI-test API is `XCUIDevice.voiceOverService` (`XCUIVoiceOverService`: `enable`/`disable`, `moveForward`/`moveBackward`/`moveIn`/`moveOut`, `currentSpeech()` → spoken text). It might reach system-drawn UI the snapshot misses (iPad tab bar); untested. Snapshots are unchanged since iOS 17: still no hit points, visibility or traits (`isHittable` only on live elements).
- **XCUITest idle wait:** no public control. Swapping the private `shouldSkipPreEventQuiescence` / `shouldSkipPostEventQuiescence` to YES (tested on the iOS 26.5 sim) cut taps from 0.37–0.82 s to 0.34–0.45 s, so only ~30%; ~0.35 s is event delivery itself. Long device taps (2.2 s) are mostly the app being busy. **Not worth the private-API risk.**
- **System-drawn UI:** XCUITest marks such elements `isRemoteLeafPlaceholder` (same marker the bridge reports). Public options to try: query `com.apple.springboard`'s tree, or the VoiceOver walk.
- **Other useful public APIs:** `performAccessibilityAudit` (iOS 17) → `ios a11y audit`; `XCUIDevice.appearance` / `location` / `system.openURL`; pinch/rotate/two-finger gestures.
- **Known issues (Xcode 27):** simulator keyboard/mouse input requires iOS 18+; the software keyboard may not appear for up to 2 minutes after "Simulate Hardware Keyboard" (affects `type`); "Toggle Software Keyboard" broken on iPad simulators on iOS 27.0.
- **Other Xcode 27 tooling:** `lldb-mcp` (LLDB's own MCP server; could host the LLDB accessibility/SwiftUI dumps), `xctrace export --time-start/--time-end` (scriptable SwiftUI Instruments data), `xcindex-test` (diagnostic; may give per-file compiler arguments for find-usages).

## 3. Input synthesis

| Approach | Result |
|---|---|
| `simctl` / `devicectl` | No tap/swipe/type (confirmed Xcode 27). |
| LLDB `accessibilityActivate` | Returned `NO` on iOS 26 glass tab bar. ❌ |
| AXe / idb (private HID) | Not tested; simulator-only by design. |
| **XCUITest runner** (Spike A, sim) | ✅ Tap (tab-bar tab → Selected), swipe (header y 459.8 → −36.9), type (search query → results) on iOS 26.5. Tap 0.7–1.9 s, swipe 3.5 s, type 10 chars 0.7 s, activate app 0.17–0.35 s. Slowness = XCUITest idle-wait (WebDriverAgent swizzles a private method to remove it). |
| **XCUITest runner** (Spike E, physical iPad) | ✅ Tap (tab-bar tab, confirmed by screenshot), swipe, focus + type (search query → `value: <query>, Keyboard Focused` and results), screenshot returned over the socket. Tap 0.7–2.2 s, swipe 2.3 s, type 0.6 s, tree 0.1–0.7 s, screenshot 0.25 s, runner ready 4.4–11 s after `test-without-building`. `typeText` with no focused element fails the test and ends the server → the runner checks `hasKeyboardFocus` first and returns an error. |
| **Xcode bridge** | ✅ Real tap in 0.84 s incl. new screenshot + hierarchy (iOS 27 sim). |

Bridge command language (from Xcode's exported `device-interaction` skill):

| Command | Meaning |
|---|---|
| `t x y [dur]` | Tap / long-press |
| `d x y` | Double tap |
| `t x1 y1 f x2 y2 [dur]` | Swipe |
| `drag x1 y1 x2 y2 [hold] [move]` | Drag-and-drop |
| `mt [x y, …] dur [x y, …] dur …` | Multi-touch (pinch, etc.) |
| `b h/p/u/d [dur]` | Home / Power / Volume up / Volume down |
| `sender keyboard kbd <text>` | Type text (`\u{000A}` = Return) |
| `w dur` | Wait |
| `orientation portrait/landscapeLeft/…` | Rotate |
| `b c/s/a`, `c <rot>` / `r up/down/…` | watchOS / tvOS controls |

---

## 4. Xcode 27 MCP bridge — facts established

**Architecture.** `xcrun mcpbridge` is a stdio↔XPC bridge. Almost all tools are served by **`Xcode.app/Contents/Developer/Library/Xcode/Agents/Xcode Service.app`**, a background process launched on demand (~700 MB RSS). A throwaway project was created, built, previewed, run and tested **without ever getting an Xcode window**, and builds did not steal focus.

**Management CLI — `xcrun mcp-server`:** `status [--format json]`, `open <paths>`, `stop`, `show-logs` (per-call timings in `~/Library/Logs/Xcode/XcodeService/`); with sudo: `enable`/`disable` (headless mode), `approve [--always|--for-24-hours]`, `allow-folder`, `clear-permissions`, `deny`, `reset-all`.

**Headless mode is official (early preview).** Release note 181836944: "Xcode 27 Beta 5 adds a preview of a new MCP server experience that runs without requiring an open Xcode workspace", with long-term permissions for code-signed agents over a directory tree. For CI: `sudo xcrun mcp-server enable --unsafe-always-allow-all-agents` ("not a recommended configuration for at-desk use"). Some settings changes "may occasionally require relaunching Xcode or rebooting".

**Approval model.** Per **client binary** (path + hash) and per **folder**. Unsigned binaries get 24 h trust; `--always` requires a **signed** client → `ios` must ship code-signed. First call on a new folder blocks ~60 s then errors until approved from Xcode's menu-bar extra or `mcp-server approve`.

**Constraints.**
1. Device interaction requires **iOS/watchOS/tvOS 27+ simulators**. Physical devices are rejected even on iOS 27.0.1 with Developer Mode + *Enable UI Automation* on: `The device you are targeting is not supported for Device Interaction. Supported: iOS [Simulator] 27.0+; …`. `IDEDeviceInteraction.framework` (Xcode 27.0, 27A266a) only contains simulator implementations (`SimulatorDevice`, `SimulatorDestinationProvider`, `IDESimulatorDeviceTrampoline`); the ECID mention in the tool schema suggests device support is planned. The same iPad *is* an eligible run destination for builds (`XcodeListRunDestinations` → `isEligible: true`). Re-check on each Xcode release.
2. Interaction **sessions expire after 60–120 s idle** (alive at 30 s and 60 s gaps, gone at 120 s) → daemon keep-alive or transparent re-create.
3. `workspaceIdentifier` must be the **id** returned by `XcodeOpenWorkspace`; passing a path fails despite the schema. Closing a workspace invalidates its id.
4. Run destinations are selected by **display title**, not UDID (ambiguous with duplicate simulator names).
5. `RenderPreview` ignores the run destination and boots its own simulator.
6. Test tools use the **active scheme's** test plan only (the test app's active scheme had no test plan → 0 tests).
7. Not a documented public API; may change per Xcode release.

**Tool timings (Spike B, throwaway SwiftUI app):**

| Tool | Time | Notes |
|---|---|---|
| `XcodeListTemplates` | 0.2 s | 52 templates; iOS App options: language, UI, testing (None/XCTest/Swift Testing), storage (SwiftData/Core Data) |
| `XcodeNewProject` | 1.7 s | app + unit + UI test targets |
| `XcodeOpenWorkspace` | 0.17 s | 0.01 s if already open; idempotent |
| `XcodeListSchemes/Targets/RunDestinations`, `GetTargetBuildSettings` | ≤ 0.04 s | 572 settings, raw + evaluated |
| `BuildProject` | 4.1 s cold / 2.0 s incremental | `GetBuildLog`, `XcodeRefreshCodeIssuesInFile` (0.47 s) OK |
| `RenderPreview` | 31.9 s cold / 0.15–0.42 s warm | dark mode, Dynamic Type AX5, orientation, contrast overrides verified |
| `RunProject` / `StopProject` / `GetConsoleOutput` | 2.1 s / 0.01 s / 0.02 s | |
| `GetTestList` / `RunAllTests` | 0.07 s / 85 s (3 tests) | per-test pass/fail + `.xcresult` path |
| `DeviceInteractionSynthesize` | 0.84 s (tap + capture) | |

---

## 5. Documentation (`docs`)

**Android reference:** 20.6 MB zipped KB, 5,319 full-text articles in `~/.android/cli/docs`, local index, `fetch kb://…` → markdown linking to skills.

**iOS (Spike D, prototype `docs.py`):**

| Piece | Result |
|---|---|
| Catalog + framework indexes (`tutorials/data/documentation/technologies.json`, `tutorials/data/index/<fw>`) | 395/395 frameworks, 0 failures, 137 MB raw in 30.5 s (4 workers, polite). No platform/availability per node; `deprecated` + `beta` flags only. |
| SQLite FTS5 search index | 363,442 pages (267,688 Swift + 95,754 ObjC-only), built in 7.6 s; **118.9 MB raw → 17.9 MB zstd-19**. bm25 + kind boosts + deprecated/ObjC penalties + multi-word framework detection. 10 realistic queries: 46–173 ms, 8 good / 2 acceptable. |
| `fetch` (DocC JSON → markdown) | 0.4–1.0 s live. Availability, declaration, parameters, headings, code, asides, lists, term lists, **tables**, `doc://` links for chaining. Images → placeholders. |
| `api` (offline symbol graphs) | 6 modules (SwiftUI, Foundation, UIKit, AVFoundation, SwiftData, Observation): 127,071 symbols in 38 s; compacted + doc dedup → **4.9 MB zstd**. Lookup 230–350 ms (< 50 ms with an indexed column). |
| Caveat | ObjC-imported frameworks carry little doc text in symbol graphs (UIKit 16%, AVFoundation 16% vs SwiftUI 99%) → `api` = exact signatures/availability for the installed SDK; prose comes from `fetch`. |
| Search gaps | No iOS-vs-macOS preference (no platform data in index); intent queries ("push notification register") need abstracts/synonyms. |

**Shipping strategy (hybrid):**
1. **Prebuilt site index** (~18 MB zstd), refreshed weekly in CI (30 s crawl + 8 s build), downloaded on first use with ETag — same model as Android CLI.
2. **Symbol graphs built locally per Xcode build** (~40 s for top modules, rest on demand) — must match the installed SDK/betas.
3. **Live `fetch`** with a disk cache; optionally pre-cache article bodies for full-text search.

Proposed commands:

```
ios docs search "navigation destination" [--framework SwiftUI] [--kind method] [--json]
ios docs fetch  doc://swiftui/view/navigationdestination(for:destination:)
ios docs api    SwiftUI.View.navigationDestination
ios skills list | add | remove | update
```

---

## 6. CI / no-bridge path (Spike C)

| Step | Result |
|---|---|
| `info` | < 1 s total, all JSON |
| `xcodebuild -list -json` (test app workspace) | 10.3 s, 20 schemes |
| `-showBuildSettings -json -scheme App-Dev` | 42 s cold (package resolution), 8 s warm → bundle id, product, build dir |
| `swift package describe` | 0.6 s (4 local packages) |
| Build the app, iOS 27 sim | clean 84 s, no-op 20 s, no signing/secrets issues |
| Boot / install / launch | 25 s / 4.3 s / 0.8 s |
| Logs | `log stream --style ndjson` (skip non-JSON preamble); `print()` needs `--console-pty` |
| `sourcekit-lsp` definition | ✅ ~10 ms with a real compilation DB (`AppModel()` → `AppModel.swift:22`) |
| `sourcekit-lsp` references | ❌ index DB not created via config; index store itself is complete (2,592 units, `AppModel` usages in 5 files) → read with **`indexstore-db`** directly |
| Compile DB for Xcode projects | Needs `xcode-build-server` or parsing xcodebuild logs |

Design implication: xcodebuild metadata calls are slow → **cache `describe` output keyed on project file mtimes**; prefer bridge equivalents when available.

---

## 7. Architecture

```
                    ┌──────────────────────────────┐
  human / agent ───▶│  ios  (Swift, ArgumentParser,│──▶ JSON / text output
                    │        code-signed)          │
                    └──────────────┬───────────────┘
      ┌───────────────┬────────────┼──────────────┬────────────────┐
      ▼               ▼            ▼              ▼                ▼
 xcodebuild      simctl /      iosd (daemon)   docs store      skills store
 swift pkg       devicectl     ├ bridge conn   ├ site index    (Xcode export
 (cached         log stream    │  + sessions   │  (FTS5)        + ours)
  describe)                    ├ XCUITest      ├ symbol DB
                               │  runner(s)    └ fetch cache
                               └ keep-alive /
                                 idle close
                                     │
                     ┌───────────────┴───────────────┐
                     ▼                               ▼
           Xcode Service (MCP)              XCUITest runner
           iOS 27+: layout, input,          any iOS: layout, input
           build, run, previews,            (sim verified; device TBD)
           tests, create, diagnostics
```

- **Backend selection for `layout`/`input`:** bridge if target is a simulator with OS ≥ 27 and approved → XCUITest runner (older simulators + **all physical devices**) → LLDB AX walk (sim, read-only, last resort).
- **Output contract:** every command supports `--json`; one `--device <udid|name>` resolver across sim/device (bridge needs display title → resolver maps UDID → title).
- **Daemon (`iosd`):** owns bridge connection + interaction session (re-create on 60–120 s expiry), XCUITest runner lifecycle, closes idle resources.
- **`ios init`:** checks Xcode version, triggers bridge approval (or prints `xcrun mcp-server approve` guidance), downloads docs index, exports Xcode skills.
- **Language / distribution:** Swift + `swift-argument-parser`; signed + notarized; Homebrew tap.

---

## 8. Phased plan

### Phase 0 — Feasibility ✅ (2026-10-14)
- [x] Inventory Android CLI; map to iOS primitives
- [x] UI tree + input: bridge (iOS 27 sim) and XCUITest runner (iOS 26.5 sim) both work
- [x] Bridge non-interaction tools, approval model, session lifetime
- [x] CI path: info/describe/build/run/logs on the test app
- [x] Docs: full index + fetch + symbol graphs prototype
- [ ] Decide audience priority (agents vs humans) → default output format
- [ ] Decide minimum supported target OS for interaction

### Phase 1 — Remaining spikes (≈ 1 week)
1. ~~**Physical device via bridge**~~ — done: **not supported in Xcode 27.0** (simulator-only implementation). Re-test on Xcode 27.x betas.
2. ~~**XCUITest runner on device**~~ — done (Spike E), see §3. How it works:
   - **Signing:** Automatic signing with the team's existing Xcode-managed wildcard profile (`iOS Team Provisioning Profile: *`), passed as `xcodebuild` overrides **without** `-allowProvisioningUpdates`, so nothing changes in the developer account.
   - **Transport:** TCP server inside the test (`NWListener`, port 8100), reached at the device's CoreDevice tunnel address (`devicectl device info details` → `connectionProperties.tunnelIPAddress`).
   - **Gotchas:** `xcodebuild` doesn't see the device while it's locked/offline (`devicectl` shows `unavailable`), so `ios doctor` should check this; every runner command must validate its input, because any XCTest failure ends the server.
3. ~~**Remove XCUITest idle-wait**~~ — evaluated (R2): private quiescence skip gives only ~30% (taps ≥ 0.34 s); not worth the risk. Keep the public behavior.
3b. **`ios layout --swiftui`** — productize the `SWIFTUI_VIEW_DEBUG` + `makeViewDebugData` dump (works on simulator and physical iPad); add a filter that keeps the app's own types and layout containers; reduce the ~13 s device attach if possible (possibly through `lldb-mcp`).
   - **LLDB on devices:** `lldb --batch` hangs on `device process attach` (the attach completes asynchronously); drive LLDB through its Python API (`SBDebugger.SetAsync(True)` + event listener with a timeout) instead.
3c. **Hidden system UI** — try SpringBoard's tree and `XCUIVoiceOverService` for the iPad floating tab bar.
3d. **`devicectl` JSON v5** — `connectionProperties` / `deviceProperties` / `hardwareProperties` are deprecated in favor of a `properties` dictionary; read the tunnel address and device state from the new shape.
4. **Find-usages without bridge** — `indexstore-db` over DerivedData index store; compile-DB generation via `xcode-build-server`.
5. **Bridge with Xcode GUI quit + headless mode** (`sudo xcrun mcp-server enable`; officially an early preview in Xcode 27 Beta 5+).
6. **Search quality** — add abstracts/synonyms; platform preference.

### Phase 2 — MVP (≈ 2–3 weeks), no bridge dependency

**Started 2026-10-14:** Swift package skeleton (`Sources/ios`, `Sources/IOSCore`, `Tests/IOSCoreTests`; swift-argument-parser 1.8.2). Working: `ios info`, `ios sim list`, `ios device list` (devicectl JSON v5 with fallback), `ios screen capture` (simulator + device), `--json` everywhere, `--device <udid|name>` resolution. Remaining commands are stubs that name their phase. 10 unit tests on sanitized samples.

**`describe`, `build`, `run` done (2026-10-14)**, verified on the test app (no files in its repository changed):

| Command | Result on the test app (iPhone 18 Pro simulator, iOS 27) |
|---|---|
| `describe` | Schemes: 10.7 s cold → 0.4 s cached. App products: 6.5 s cold → 0.7 s cached (bundle ID, iOS 16.6+, path in Xcode's DerivedData) |
| `build` | 33.2 s incremental, 0 errors, 11 warnings (de-duplicated, matches the raw log); full log under `~/Library/Caches/ios-cli/logs/` |
| `run` | 15.7 s (13.2 s build + install + launch, PID reported); `--no-build` 2.3 s |
| failure path | Deliberate type error in a throwaway copy of SpikeApp → exit 1, error with file/line/column in text and `--json` |

Design: the cache key is container + scheme + configuration + SDK + DerivedData path, invalidated by a fingerprint (path, mtime, size) of `project.pbxproj`, `*.xcscheme`, `*.xcconfig`, `contents.xcworkspacedata`, `Package.swift` / `Package.resolved` plus the Xcode build. Hidden folders are skipped, which keeps agent worktrees (`.claude/worktrees`) out. 21 unit tests. Not yet tested: `run` on a physical device (would replace the the test app build installed on the iPad).

**`install` and `logs` done (2026-10-14):**

| Command | Result |
|---|---|
| `install <app> --launch` | The app (path from `describe`) on the iPhone 18 Pro simulator: 1.8 s |
| `logs --last 1m` (simulator) | 1,359 structured entries; `--json` gives NDJSON (timestamp, level, subsystem, category, process, pid, message) |
| `logs` follow (simulator) | Streams the unified log; works piped into `head` (the child `log stream` ends when the pipe closes, no orphans) |
| `logs --launch --duration 10` (simulator) | Relaunches with the console attached; captures the app's `print()` output and `os_log` (via `OS_ACTIVITY_DT_MODE=1`) |
| `logs --launch` (physical iPad) | Works without root; devicectl's own status lines filtered out, PTY `\r` stripped |
| `logs` without `--launch` (device) | Refuses with an explanation: `log collect --device-udid` needs root |

**`docs` done (2026-10-14)** — Swift port of the `spikes/docs` prototype, no dependencies (system SQLite has FTS5; downloads via `/usr/bin/curl --parallel`):

| Command | Result (release build) |
|---|---|
| `docs search` | First run builds the index automatically (like Android CLI): 395/395 framework indexes downloaded in 5–9 s, 363,442 pages indexed, 17.7 s total, 125 MB. Queries 35–51 ms end to end (prototype: 46–173 ms); same ranking and quality on the 10 benchmark queries |
| `docs fetch` | 391 ms live, 29 ms cached (7-day disk cache); availability, declaration, parameters, asides, code, tables, `doc://` links; clear error on a missing page |
| `docs api` | Per-module extraction on first use (SwiftUI 11.8 s, SwiftUICore 3.4 s, UIKit 9.9 s), then 110–190 ms. Module names are case-insensitive (matched against the SDK's frameworks). Falls back to the `…Core` companion when there's no exact match — in iOS 27 `SwiftUI.View` is declared in `SwiftUICore` |

**REST/JS web services added (2026-10-15):** their indexes list pages under the interface language `data` (App Store Connect API, App Store Server API/Notifications, Apple Music API, MapKit JS, WeatherKit REST, CloudKit JS, Sign in with Apple REST, Apple Pay on the Web, Device Management…), which the builder skipped; now included (363,614 → 382,922 pages, API benchmark unchanged). **All remaining sources added (2026-10-15, v0.3.0):** tutorials (5 collections crawled as DocC: 181 pages; steps render with their code files), the Swift book (docs.swift.org DocC index: 44 pages), the App Store Review Guidelines (one HTML page; numbered sections parsed: 125, `asrg://4.2` renders a guideline with its sub-items), WWDC sessions 2023–2026 (titles, categories and full descriptions from each year's listing: 699; `wwdc://2026/258` fetches the timestamped transcript). One index of 383,971 pages, rebuilt in ~39 s; `docs search --source api|hig|tutorials|swift-book|app-review|wwdc`; small boosts for tutorials and the Swift book ("closures" → the book chapter); API benchmark unchanged. 63 unit tests.

**Human Interface Guidelines added (2026-10-15):** the HIG has no downloadable index (`tutorials/data/index/design` → 404) but uses the same DocC JSON, so `docs update` crawls it from `/design/human-interface-guidelines` (172 pages, ~5 s; every reference carries title and abstract). Pages are indexed as framework `hig` (abstract in a low-weight column, +1 ranking boost so "slider" / "dark mode" surface the guideline first; API benchmark unchanged except "live activity" now leads with the HIG page). `docs search --hig`, `hig://` links, and HIG pages link to their APIs (`doc://swiftui/slider`). 53 unit tests.

Fixes found while porting: Swift `Regex` made the index build ~5× slower (105 s → 20 s after a byte-level word splitter); `xcodebuild -version` cost ~0.25 s per lookup (now read from Xcode's `version.plist`). Still open from §5: a prebuilt index from CI (currently built locally from Apple's endpoints), iOS-over-macOS preference in ranking, intent queries ("push notification register"). 33 unit tests.

Finding: a device's unified log can't be read without root (`log: Must be root to collect logs from attached device`); `devicectl device process launch --console` plus `OS_ACTIVITY_DT_MODE=1` is the non-root path, at the cost of relaunching the app. 28 unit tests.
`ios info · sim (list/create/boot/shutdown/erase) · runtime · describe (cached) · build · install · run · logs · screen capture · docs search/fetch/api`

### Phase 3 — Interaction & IDE (≈ 2–3 weeks)

**`layout` / `input` on the XCUITest runner backend done (2026-10-14)** — works on every target type; the Xcode-bridge backend (faster, iOS 27+ simulators only) is still to add.

- Runner ships as a package resource (`Sources/IOSCore/Resources/Runner`), built on first use per Xcode build/platform/team/source hash (simulator: ad-hoc; device: team from `--team`, `IOS_CLI_TEAM`, or a local wildcard profile covering the device — no developer-account changes unless `--allow-provisioning-updates`).
- No daemon: the detached `xcodebuild test-without-building` process is the server; state file per target; TCP to `127.0.0.1` (simulators, port derived from the UDID so several can run) or the CoreDevice tunnel (devices, port 8100). Runners built from older code are restarted automatically; a leftover runner on the port is told to quit; the runner exits if it can't bind its port.
- `ios input tap --id/--label` taps the visible centre of the element from a fresh snapshot; keyboard focus is marked via a `hasKeyboardFocus` query (snapshots only carry tvOS focus); a background app or a missing element gives an actionable error.

| Check | iPhone 18 Pro simulator (iOS 27) | Physical iPad (iOS 27.0.1) |
|---|---|---|
| First use (build + start runner) | 16.8 s | 15.8 s |
| `layout` (warm) | 0.68 s | 1.04 s |
| `input tap --id …` | 0.4–0.8 s | 1.1–1.5 s |
| `input type` | 0.56 s (value confirmed in tree) | 0.67 s (search results appeared) |
| swipe / Home | 0.81 s / 0.48 s | — |

**`layout --swiftui` done (2026-10-15)** on the simulator and the physical iPad (20 s on the iPad, 184 lines / 33 `Text` nodes for the test app's home screen). Two device fixes: wait for a real "stopped" state-change *event* (polling `GetState()` reads "stopped" while the attach is still only "connected"), and let LLDB settle and retry `@import UIKit` before evaluating. SwiftUI's debug data records most custom views only inside generic parameters (`Button<App.ItemCard>`), so each node is annotated with the app types it names: `LazyHStack ‹ItemCard, AvatarCard›`.
- `--relaunch` starts the app with `SWIFTUI_VIEW_DEBUG=1`; LLDB (Python API, async attach with timeout, embedded script) calls `makeViewDebugData` on every `_UIHostingView`, files are read from the simulator container or copied off the device.
- Output keeps the app's own types (any non-SDK module, so the app's own frameworks count) and SwiftUI structure (stacks, lists, navigation, `Text` with its string…); modifiers and internals are collapsed. Example (test app welcome screen, names changed): `WelcomeView → GeometryReader → ZStack → [Image, VStack → [Spacer, Image, VStack → Text "…" …]]`. `--raw` prints SwiftUI's unfiltered data.
- Findings: SwiftUI lists children last-to-first (reversed to screen order); the debug data appears a few seconds after first render, so `--relaunch` retries (two reads, ~20 s); reading a running app takes ~4.4 s on a simulator. The relaunch → `ios input` → `layout --swiftui` workflow works (the runner activates the app without relaunching it). UIKit screens presented over SwiftUI don't appear (the SwiftUI views underneath do).

**`preview` and `create` done (2026-10-15)** on a Swift MCP client for `xcrun mcpbridge` (`Sources/IOSCore/Bridge`):

| Command | Result |
|---|---|
| `create SampleApp --org com.example --testing swift-testing` | 4.2 s; app + unit + UI test targets (Xcode 27's default "App" template is multiplatform; `--template ios-app` for iPhone/iPad only) |
| `create --list-templates` | Templates with options (storage, CloudKit, testing system…) — options are only returned for filtered queries, so it filters by platform |
| `preview SampleApp/ContentView.swift` | 20.3 s cold (builds), 0.37–0.51 s warm; lists variants (color scheme, contrast, control borders, Dynamic Type, orientation) and locales; `--variant "Color Scheme=Dark Appearance" --variant "Dynamic Type=AX 5"` verified visually |
| created project → `describe` / `run` / `layout` | single scheme picked automatically; run 24.7 s (first build); layout shows the template's globe and "Hello, world!" |

Findings: `RenderPreview` needs the file's project-navigator path, found via `XcodeGlob` by file name and matched on trailing folders; the approval dialog is only triggered by opening or creating a project (`XcodeListTemplates` alone just fails), so the error message tells the user which command triggers it; the approval carried over to rebuilt debug binaries and the installed release binary (so the per-binary-hash concern from Spike B didn't show up in practice). 47 unit tests.

**Field fixes from the first real use (2026-10-15)**, reported by an agent session working on the test app on the iPad:
- *Sheet missing from `layout`:* the visibility filter used the first window's frame as the screen; with iPad form sheets that window is smaller than the display, so a sheet drawn outside it was dropped. Now the application frame is the screen (regression test with that layout).
- *Tap reported "timed out" although it worked:* XCUITest waited 60 s for the continuously animating app to go idle after the tap ("App animations complete notification not received"), and the client timeout was also 60 s. The runner now skips XCUITest's pre/post-event idle waits (private `XCUIApplicationProcess` switches, as WebDriverAgent does; guarded, `IOS_CLI_WAIT_FOR_IDLE=1` restores them); client timeout 120 s; a missing reply after the command was sent now says "may or may not have happened" instead of "unreachable"; a busy runner is waited for instead of restarted.
- *Raw xcodebuild dump when UI Automation is off:* start failures now explain it (Settings → Developer → Enable UI Automation, unlock).
- *Sheet still missing after the filter fix (even with `--full`):* reproduced on a simulator with a SwiftUI `.sheet` over a `.fullScreenCover`. XCUITest snapshots honor accessibility modality: the full-screen cover is modal, so its siblings — including the sheet presented on top of it — were pruned, although XCUITest's own `debugDescription` and VoiceOver-level data still had them. Apple's docs and the public XCTest headers have no API for this (checked with `ios docs`); the runner now snapshots with XCTest's default parameters plus `snapshotKeyHonorModalViews = false` via the private `-[XCUIElement snapshotWithParameters:error:]` (defaults reached through `XCUIDevice.shared.accessibilityInterface`; all limits are already 2147483647), and queries use `includingNonModalElements`; both guarded with fallbacks. Elements on layers under a later full-screen presentation are marked `covered`, and `tap --id/--label` prefers what's on top. Labeled SwiftUI Toggles are tapped on their switch, not the row centre (which hits the label and doesn't toggle).
- *`.accessibilityHidden` views listed by `layout`:* not caused by the modal change; XCTest's public `snapshot()` lists them too (its tree holds automation elements, which include views hidden from assistive technologies), and snapshots expose no "is accessibility element" attribute. Added `ios layout --voiceover` (v0.3.1): the runner walks the screen with Xcode 27's public `XCUIVoiceOverService` (`enable`, `currentSpeech`, `moveForward` until VoiceOver stops advancing), returns the utterances in order, and switches VoiceOver back off if it turned it on. Verified: hidden speaker images are absent from the VoiceOver list while `layout` shows them.
- *`--voiceover` on a sheet over a full-screen cover read the screen behind the sheet* (reported on the iPad): reproduced on a simulator. A sheet presented from a plain screen is read correctly (VoiceOver stays inside it); a sheet presented from inside a `.fullScreenCover` is never reached — also when VoiceOver is already on before the sheet appears and the screens are opened VoiceOver-style (focus + double-tap). The walk starts at VoiceOver's own focus and follows its own navigation, so this most likely reflects what VoiceOver users get (an app/SwiftUI accessibility issue, to confirm manually). v0.3.2: the app-name prefix VoiceOver adds to the first element is stripped, and utterances captured mid-speech are compared by prefix (no duplicates); runner has `voiceover on|off` for such experiments.
- *Keyboard focus without a query (v0.3.3):* XCTest's snapshot objects carry `hasKeyboardFocus`, so `snapshot` no longer runs a separate focus query (guarded fallback); `type` keeps its own check.
- After the idle-wait fix, `layout` on the test app's practice screen takes ~1 s and taps 0.45–0.74 s on the iPad (was 60 s per action).

Tap points match the Xcode bridge's hit points exactly on the same screen ("Get started" (201,722), "Sign In" (201,788)). Behaviors to know: stopping a runner closes the app it drove (XCTest cleanup), so restarts relaunch it; reads right after launch can show the loading state. 40 unit tests.
`iosd` daemon · `ios layout [--flat|--full]` · `ios input tap|swipe|type|button|rotate` · `ios screen resolve` · `ios preview render` · `ios create` · `ios test` · `ios check <file>` (diagnostics) — bridge first, XCUITest fallback.

### Phase 4 — Ecosystem

**`ios skills` done (2026-10-15):** `list`, `add <names>|--all`, `remove`, `update`, into `~/.claude/skills` (`--project`, `--dir` for other agents). Sources: the bundled `ios-cli` skill (now a package resource, so `ios skills add ios-cli` works without the repo; `install.sh --skill` uses it) and Xcode 27's 10 skills via `xcrun mcpbridge run-agent skills export` (cached per Xcode build; 0.1 s). A marker file in each installed skill keeps `update`/`remove` away from hand-made skills unless `--force`. 50 unit tests.
`ios skills` (Xcode skills + team-specific), Claude Code skill for the `ios` CLI, shell completions, `ios update`, weekly docs-index CI job.

---

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Bridge is undocumented; may change per Xcode release | High | Backend abstraction; contract tests on each Xcode beta; XCUITest fallback |
| Bridge interaction is iOS 27+ **simulator-only** | Medium | XCUITest runner covers older OS and all physical devices |
| Approval friction (per binary hash + folder; unsigned = 24 h) | Medium | Ship signed; `ios init` guides approval / `mcp-server approve --always` |
| Session expiry 60–120 s; Xcode Service ~700 MB | Low | Daemon keep-alive + idle shutdown |
| XCUITest input latency (0.7–3.5 s) | Medium | Idle-wait removal spike; prefer bridge on iOS 27+ |
| Device signing for run / XCUITest runner | Medium | Reuse project team; `ios doctor` |
| xcodebuild metadata slowness (10–42 s) | Medium | Cache keyed on project mtimes; bridge equivalents |
| DocC JSON is unofficial | Medium | Weekly CI canary; symbol-graph fallback |
| Overlap with XcodeBuildMCP / AXe / idb / WDA | Low | Differentiate: unified UX, Xcode 27 bridge, docs, skills |

---

## 10. Open questions

- Is iOS 27-only bridge interaction acceptable for v1, with XCUITest as the older-OS path?
- CI usage: is the no-bridge mode (Phase 2) enough, or do we need headless bridge in CI?
- Ship the docs index prebuilt from our CI (recommended) or build on install?
- Internal tool first, or open source from day one?

---

## Appendix — Prototypes and evidence

Small reference prototypes are in [`spikes/`](spikes/README.md) (MCP bridge client, LSP probe, the Python docs prototype, LLDB scripts). Raw evidence from the study — screenshots, UI and SwiftUI dumps, logs and build output from the test app — is deliberately kept out of this repository.
