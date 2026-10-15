# Spikes

Small prototypes from the feasibility study, kept as references. The production implementations live in `Sources/`; raw evidence from the study (screenshots, UI dumps, logs, build output of the app used for testing) is intentionally not part of this repository.

| Folder | What it is | Superseded by |
|---|---|---|
| `bridge/` | Minimal stdio MCP clients for Xcode 27's `xcrun mcpbridge` (`mcp_call.py` runs a sequence of tool calls; `$prev.<field>` substitutes values from the previous result) | — (basis for `ios preview` / `ios create`) |
| `lsp/` | `sourcekit-lsp` probe with a compilation database: go-to-definition works; references need `indexstore-db` | — (find-usages is still open) |
| `docs-prototype/` | Python prototype of `ios docs`: index download, FTS5 index build, DocC→markdown, symbol graphs | `Sources/IOSCore/Docs/` |
| `lldb/` | LLDB scripts: accessibility-tree walk and `accessibilityActivate` (simulator), async attach to a process on a physical device | `Sources/IOSCore/SwiftUITree.swift` (embedded attach script) |

Notes:
- The accessibility walk only returns elements after enabling the simulator's accessibility automation (`defaults write com.apple.Accessibility ApplicationAccessibilityEnabled/AutomationEnabled -bool true` via `simctl spawn`); restore it afterwards.
- `lldb --batch` hangs on `device process attach`; use the async Python API as in `device-attach.py`.
