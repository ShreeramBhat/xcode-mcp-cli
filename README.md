# xc — Xcode's MCP tools as a command-line tool

`xc` turns every tool in Xcode 27's MCP server (`xcrun mcpbridge`) into a shell command:

```sh
xc build                                  # BuildProject in the workspace found from the cwd
xc test                                   # RunAllTests
xc grep 'TODO' --output-mode content      # XcodeGrep
xc console --oslog-severity error         # GetConsoleOutput
xc build --json | jq '.errors'            # structured output for scripts
```

It's useful when an AI agent works with Xcode. Registered as an MCP server, Xcode's ~54 tool
definitions sit in the agent's context for the whole session. As a command-line tool, the agent
calls `xc` only when it needs to, and the output goes straight into `jq`, `grep`, scripts and CI.

- **Covers every tool, no fixed list.** Subcommands and flags come from the tool definitions
  Xcode itself reports, so tools added in future Xcode builds show up automatically.
- **No dependencies.** A single Python 3.9+ file; the system Python on macOS is enough.
- **Keeps the connection open.** A small background process holds one `mcpbridge` session per
  calling agent, so repeated calls skip the bridge startup and handshake.

## Requirements

- macOS with Xcode 27 (or any Xcode that ships `xcrun mcpbridge`)
- Xcode → Settings → Intelligence → **Allow external agents to use Xcode tools**

## Install

```sh
git clone https://github.com/ShreeramBhat/xcode-mcp-cli.git
ln -s "$PWD/xcode-mcp-cli/xc" ~/.local/bin/xc     # any directory on your PATH
xc tools
```

## Usage

```sh
xc tools                       # every tool, with its short name
xc help <tool>                 # flags for one tool, from its definition
xc schema <tool>               # the tool's raw definition
xc <tool> [values] [--flags]   # call a tool
```

**Tool names.** You can use the original name (`XcodeListWorkspaces`), a kebab-case version
(`xcode-list-workspaces`, `list-workspaces`) or a short alias (`workspaces`). Short aliases
include `build`, `run`, `stop`, `test`, `tests`, `open`, `close`, `ls`, `read`, `write`, `edit`,
`grep`, `glob`, `mv`, `rm`, `mkdir`, `schemes`, `scheme`, `targets`, `destinations`,
`destination`, `docs`, `log`, `console`, `lldb`, `preview`, `snippet`, `issues` and `settings`.

**Arguments.**

| Kind | Example |
|---|---|
| Required values, in order, without flags | `xc grep TODO`, `xc read Sources/App.swift` |
| Flags, in kebab-case or camelCase | `--head-limit 5`, `--headLimit 5` |
| True/false values | `--ignore-case`, `--no-ignore-case`, `--ignore-case=false` |
| Lists (flag can repeat, or take a JSON array) | `--oslog-severity error --oslog-severity fault` |
| Objects (JSON or `key=value`, flag can repeat) | `--options languageChoice=Swift --options coreData=false` |
| Raw JSON | `--args '{"query":"SwiftData"}'`, or `--args -` to read stdin |
| Show the request without sending it | `--dry-run` |

**Workspace.** For tools that take a `workspaceIdentifier`, `xc` uses `-w/--workspace`, then
`$XC_WORKSPACE`, then the nearest `.xcworkspace` or `.xcodeproj` above the current folder.

**Output.** By default you get readable text. `--json` prints the structured result and `--raw`
prints the full MCP response. Images such as preview renders are saved to a file (`-o DIR` picks
the folder) and the path is printed. Exit codes: `0` success, `1` the tool reported an error,
`2` usage or connection error.

## Approving access

Xcode asks the user to approve an agent the first time it opens or creates a project:

```sh
xc open path/to/App.xcodeproj      # Xcode shows an approval prompt
```

Or approve from the terminal. These commands wrap `xcrun mcp-server` and add `sudo` where needed:

```sh
xc status                          # agents, folders, pending requests, open workspaces
xc approve <id> --always           # approve a pending request
xc allow-folder ~/Code --always    # pre-approve every project under a folder
xc deny <id>
xc logs                            # agent activity log
xc server <command> [args]         # any other `xcrun mcp-server` command
```

> **Check what the prompt names.** Xcode trusts agents by code signature. If the prompt names the
> Python interpreter rather than your agent, an "Always" grant would cover any Python script that
> starts `mcpbridge`. In that case prefer "Allow for 24 Hours".

## The background connection

The first call starts a background process that keeps one `mcpbridge` session open and listens on
a Unix socket in `~/Library/Caches/xc/run/`, which only your user can open. Later calls connect
to it rather than starting a new bridge.

- **One per agent.** It's tied to the nearest ancestor that isn't a shell or wrapper, for example
  the `claude` or `copilot` process. Different agents and terminals never share a connection.
  If there's no such ancestor (an orphaned call), `xc` connects directly.
- **Concurrent calls.** Several calls can run at once over the same connection. Each call's
  progress messages go to that caller only, and Ctrl-C or `--timeout` cancels only that call.
- **Shutdown.** It exits after `XC_IDLE_TIMEOUT` seconds with nothing to do (default 600), when
  its agent exits, or when `mcpbridge` exits. The next call starts a fresh one.

```sh
xc daemon                 # list background processes: owner, uptime, idle time, call count
xc daemon stop [--all]    # stop this agent's (or every) background process
xc build --no-daemon      # connect directly for one call (or set XC_NO_DAEMON=1)
xc build -v               # show which background process and log file are used
```

On one machine, a warm call took about 0.07s, against about 0.17s with a fresh bridge. If Xcode's
MCP server is cold, the first call takes longer either way.

## How it works

```
xc ──unix socket──▶ background process ──stdio──▶ xcrun mcpbridge ──▶ Xcode (XcodeService)
       (or directly: xc ──stdio──▶ xcrun mcpbridge)
```

`xc` is an ordinary MCP client. It sends `initialize`, then `tools/list` (cached per Xcode build in
`~/Library/Caches/xc`), then one `tools/call`. It doesn't touch Xcode through any other channel,
so Xcode's own approval rules apply unchanged. `xc refresh` clears the tool cache.

## Related projects

- [4rays/xbridge](https://github.com/4rays/xbridge): Swift command-line tool with a per-user background process
- [dazuiba/xcode-cli-skill](https://github.com/dazuiba/xcode-cli-skill): Node command-line tool plus an agent skill
- [SoundBlaster/XcodeMCPWrapper](https://github.com/SoundBlaster/XcodeMCPWrapper): MCP proxy that fixes Xcode's responses for strict clients

## License

MIT
