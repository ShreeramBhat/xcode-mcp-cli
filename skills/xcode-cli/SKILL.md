---
name: xcode-cli
description: >-
  Primary way to work with Xcode and Apple-platform projects (iOS, macOS, watchOS, tvOS,
  visionOS): use the `xc` command-line tool for opening workspaces, schemes and run
  destinations, building, running, testing, SwiftUI previews, console output, lldb
  debugging, compiler diagnostics, project files and groups, build settings, entitlements,
  Info.plist, String Catalogs, crash and performance reports, and Apple documentation
  search. `xc` is the only gateway to Xcode's MCP tools (`xcrun mcpbridge`); don't connect
  to the Xcode MCP server directly. Use `xcodebuild`, `xcrun simctl`, `swift build/test`
  and other CI/CD commands only as a fallback. Use whenever a task involves an .xcodeproj,
  .xcworkspace, Package.swift app, Swift/Objective-C app code, or anything Xcode does.
---

# Xcode through `xc`

`xc` is a command-line front end for Xcode's MCP server. Internally it's a client for
`xcrun mcpbridge`, so every Xcode MCP tool is available as an `xc` subcommand with the same
behaviour and the same Xcode approvals. A background process keeps one bridge session open per
agent, so calling `xc` many times is cheap (about 0.1s per call).

## Rules

1. **`xc` is the gateway to Xcode.** Use it for everything Xcode can do: workspaces,
   schemes, destinations, building, running, testing, previews, debugging, diagnostics, project
   files, build settings, localization and documentation.
2. **Never connect to Xcode's MCP server directly.** Don't call `xcode` MCP tools
   (`mcp__xcode__*`, `xcode/...` or similar) even when they're registered, and don't start
   `xcrun mcpbridge` yourself or write JSON-RPC to it. If both an MCP tool and `xc` can do
   something, use `xc`.
3. **Command-line build tools are fallbacks only.** That includes `xcodebuild`, `xcrun simctl`,
   `xcrun devicectl`, `swift build` / `swift test`, `xcresulttool`, `agvtool`, `fastlane`, and
   editing `project.pbxproj` by hand. Use them only when:
   - `xc` isn't installed, or Xcode can't run here (headless CI, no GUI session);
   - `xc tools` has no tool for the job (for example archiving, exporting or notarizing);
   - `xc` still fails after the recovery steps below; or
   - the user explicitly asks for that command.

   When you fall back, say why in one line, and keep the same workspace, scheme,
   configuration and destination you were using with `xc`.
4. **A failed build or test is a result to diagnose with `xc`** (`xc log`, `xc issues`,
   `xc console`, `xc lldb`). It's not a reason to switch to `xcodebuild`.
5. **Don't change Xcode permissions yourself.** Give the user the command and let them run it.
   Never run `xc server enable --unsafe-always-allow-all-agents`, `clear-permissions`,
   `reset-all` or `deny` unless the user asks for that exact action.

## Workflow

```sh
xc tools                                   # what this Xcode offers (authoritative)
xc help <tool>                             # flags for one tool

xc workspaces                              # what's open, with identifiers
xc open /abs/path/App.xcodeproj            # open the intended project if it isn't
xc schemes && xc scheme "App"              # confirm or switch the scheme
xc destinations && xc destination "iPhone 17 Pro"   # confirm or switch the run destination

xc build --json | jq '{buildResult, errors}'
xc log --severity error                    # build log, filtered
xc issues Sources/Feature/View.swift       # live compiler diagnostics for a file

xc tests --json                            # discover test identifiers
xc run-some-tests --tests '{"targetName":"AppTests","testIdentifier":"AppTests/testLogin()"}'
xc test                                    # whole active test plan

xc run && xc console --tail-limit 200      # run the app, then read its output
xc lldb "bt"                               # in an active debug session (xc run --attach-debugger)
xc stop

xc preview Sources/Feature/View.swift -o /tmp/previews   # render a SwiftUI preview, print the PNG path
xc docs "SwiftData relationships"          # search Apple developer documentation
```

- **Pick the workspace explicitly** whenever more than one is open: pass `-w <identifier or
  path>` on every workspace-specific call. Without it Xcode chooses, and `xc` doesn't guess.
- **One Xcode or several.** By default `xc` uses the background Xcode Service. `-X <pid>`
  targets a specific running Xcode app (`xc instances` lists them with their window tabs); there,
  `-w` takes a tab identifier.
- **Parallel agents need separate checkouts.** Two builds of the same project path collide
  (`database is locked`), even in separate Xcode instances. Use a separate `git worktree` per
  agent.
- **Confirm the scheme and destination before you build, run or test.** Switching them changes
  what the user sees in Xcode, so only switch when the task needs it.
- **Use `--json` whenever you parse output.** It prints the tool's structured result. Exit codes:
  `0` success, `1` the tool reported an error, `2` usage or connection error.
- **Long operations** such as `build`, `test`, `run` and `preview` wait until they finish. Run
  them in the foreground with a generous timeout. Don't run several in parallel against the
  same workspace.

## Project files

- **Adding, moving, renaming or deleting files or groups that belong to the Xcode project:**
  use `xc write`, `xc mv`, `xc rm` and `xc mkdir`. They work on the project navigator, so target
  membership and groups stay correct. Don't hand-edit `project.pbxproj`.
- **Editing the contents of existing files:** your normal file-editing tools are fine (`xc edit`
  also works). Afterwards, run `xc issues <file>` to check for compiler diagnostics.
- **Build settings, compiler flags, entitlements and Info.plist:** use `xc settings`,
  `xc update-target-build-setting`, `xc get-file-compiler-flags`,
  `xc update-file-compiler-flags`, `xc add-entitlement` and `xc add-info-plist`.

The full command list, grouped by area with required values and flags, is in
[references/tools.md](references/tools.md).

## When `xc` fails

| Symptom | What to do |
|---|---|
| `xc: command not found` | It's at `https://github.com/ShreeramBhat/xcode-mcp-cli`. Ask the user to install it; don't fall back without telling them. |
| "This agent isn't approved to use Xcode's tools yet" | Run `xc open <absolute project path>`, which makes Xcode show an approval prompt. Ask the user to approve it, or give them `xc status` and `xc approve <id> --always` to run themselves. |
| A folder or project access request | Ask the user to approve it in Xcode, or to run `xc allow-folder <dir> --always`. |
| "mcp-server: not running", or Xcode is closed | `xc status`. Ask the user to open Xcode, or run `xc open <project>`. |
| "lost connection to the xc daemon" | Retry once. Then `xc daemon stop` and retry. Then retry with `--no-daemon`. |
| `unknown tool` after an Xcode update | `xc refresh`, then `xc tools`. |
| An approval expired | Ask the user once to renew it. Don't try to get around it. |

Only after these steps fail, or when the tool doesn't exist, use the fallbacks in rule 3, and say
why.

## Fallback equivalents

Use these only under rule 3, and keep the same workspace, scheme, configuration and destination.

| `xc` | Fallback |
|---|---|
| `xc build` | `xcodebuild -workspace <ws> -scheme <scheme> -configuration <cfg> -destination '<dest>' build` |
| `xc test` / `xc run-some-tests` | `xcodebuild … test [-only-testing:<Target>/<Class>/<method>]` |
| `xc run` | `xcodebuild … build`, then `xcrun simctl install` / `launch` (simulator) or `xcrun devicectl` (device) |
| `xc schemes` / `xc destinations` | `xcodebuild -list` / `xcodebuild -showdestinations -scheme <scheme>` |
| `xc settings` | `xcodebuild -showBuildSettings -scheme <scheme>` |
| Swift package targets | `swift build` / `swift test` |
| Archive, export, notarize (no `xc` tool) | `xcodebuild archive` / `-exportArchive`, `xcrun notarytool` |
