# xc tool reference

Generated from Xcode's MCP tool definitions (server build 25317, 54 tools).
This table can go stale when Xcode updates; `xc tools` and `xc help <tool>` always reflect the installed Xcode.

Required values can be given in order without flags (e.g. `xc grep TODO`). Every tool that takes `workspaceIdentifier` also accepts `-w`.

## Workspaces and projects

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc close <workspaceIdentifier>` | XcodeCloseWorkspace | Closes a workspace that was opened with XcodeOpenWorkspace, identified by its workspace identifier. | — |
| `xc targets` | XcodeListTargets | Lists targets in the current Xcode workspace, optionally scoped to a single project. | `--product-type-filter` `--project-path` |
| `xc templates` | XcodeListTemplates | Lists Xcode templates available in this Xcode install. | `--category-filter` `--kind` `--name-filter` `--platform-filter` `--template-identifier` |
| `xc workspaces` | XcodeListWorkspaces | Lists the workspaces currently open in Xcode, with the identifier and path of each. | — |
| `xc new-project <templateIdentifier> <productName> <destinationPath>` | XcodeNewProject | Creates a new Xcode project from a template. | `--options` `--organization-identifier` `--team-identifier` |
| `xc new-target <templateIdentifier> <productName>` | XcodeNewTarget | Adds a new target to a project in the current Xcode workspace using a target template. | `--embed-in-app-named` `--options` `--organization-identifier` `--project-path` |
| `xc open <path>` | XcodeOpenWorkspace | Opens an Xcode workspace or project at the given path and returns its workspace identifier, which other tools can use to target it. | — |

## Schemes, destinations and test plans

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc destinations` | XcodeListRunDestinations | Lists run destinations available for the currently active scheme, grouped the same way the Xcode picker groups them (Devices, Simulators, Build, Incompatible, etc.), and identifies which one is active. | `--include-incompatible` |
| `xc schemes` | XcodeListSchemes | Lists all schemes available in the current Xcode workspace and identifies which one is currently | — |
| `xc test-plans` | XcodeListTestPlans | Lists the test plans associated with the currently active scheme and identifies which one | — |
| `xc destination <displayTitle>` | XcodeSwitchRunDestination | Changes the active run destination for the currently active scheme. | — |
| `xc scheme <schemeName>` | XcodeSwitchScheme | Changes the active scheme in the current Xcode workspace to the specified scheme. | — |
| `xc switch-test-plan <testPlanName>` | XcodeSwitchTestPlan | Changes the active test plan for the currently active scheme. | — |

## Build, run and debug

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc build` | BuildProject | Builds an Xcode project and waits until the build completes. | `--build-for-testing` |
| `xc log` | GetBuildLog | Gets the log of the current or most recently finished build. | `--glob` `--pattern` `--severity` |
| `xc console` | GetConsoleOutput | Retrieves console output (stdout, stderr, OSLog) from a running or completed app launch session. | `--context-lines` `--include-metadata` `--launch-session-reference` `--oslog-severity` `--output-type` `--pattern` `--tail-limit` |
| `xc lldb <command>` | InvokeDebuggerCommand | Sends an lldb command to Xcode's active debugging session and returns the output. | `--timeout` |
| `xc snippet <codeSnippet> <sourceFilePath> <purpose>` | RunCodeSnippet | Builds and runs a snippet of code in the context of a specific file and waits until results are available. | `--timeout` |
| `xc run` | RunProject | Builds and runs the current scheme in Xcode, equivalent to pressing the Run button (Cmd+R). | `--attach-debugger` |
| `xc stop` | StopProject | Stops the currently running app in Xcode, equivalent to pressing the Stop button (Cmd+.). | — |
| `xc issues <filePath>` | XcodeRefreshCodeIssuesInFile | Retrieves current compiler diagnostics (errors, warnings, notes) for a file in the Xcode project. | — |

## Tests

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc tests` | GetTestList | Gets all available tests from the active scheme's active test plan. | — |
| `xc test` | RunAllTests | Runs all tests from the active scheme's active test plan | — |
| `xc run-some-tests <tests>` | RunSomeTests | Runs specific tests using the active scheme's active test plan | — |

## Previews and device interaction

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc device-end <interactionSessionKey>` | DeviceInteractionEndSession | Closes previous device session created in DeviceInteractionStartSession or DeviceInteractionStartWorkspaceSession. | — |
| `xc device-run <interactionSessionKey>` | DeviceInteractionInstallAndRun | Builds, installs, and starts the current application on the currently targeted device. | `--command-line-arguments` `--environment-variables` |
| `xc device-interaction-start-session <deviceIdentifier> <sessionIdentifier>` | DeviceInteractionStartSession | Prepares a runtime for device interaction WITHOUT a workspace. | — |
| `xc device-session <sessionIdentifier>` | DeviceInteractionStartWorkspaceSession | Prepares a runtime for device interaction WITH a workspace. | `--device-identifier` |
| `xc device-input <interactSessionKey>` | DeviceInteractionSynthesize | Synthesizes device events (tap, swipe, type, etc.) on a physical device or simulator | `--activation-bundle-id` `--interaction-command` |
| `xc preview <sourceFilePath>` | RenderPreview | Builds and renders a Preview and waits until a snapshot of the resulting UI is available. | `--preview-canvas-control-overrides` `--preview-definition-index-in-file` `--preview-localization-override` `--preview-variant-overrides` `--timeout` |

## Project files (navigator-aware)

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc glob` | XcodeGlob | Finds files in the Xcode project structure matching wildcard patterns. | `--path` `--pattern` |
| `xc grep <pattern>` | XcodeGrep | Searches for text patterns in files within the Xcode project structure using regex. | `--glob` `--head-limit` `--ignore-case` `--lines-after` `--lines-before` `--lines-context` `--multiline` `--output-mode` `--path` `--show-line-numbers` `--type` |
| `xc ls <path>` | XcodeLS | Lists files and directories in the Xcode project structure at the specified path. | `--ignore` `--recursive` |
| `xc mv <sourcePath> <destinationPath>` | XcodeMV | Moves or renames files and directories in the project navigator with support for filesystem operations. | `--operation` `--overwrite-existing` |
| `xc mkdir <directoryPath>` | XcodeMakeDir | Creates directories and groups in the Xcode project structure. | — |
| `xc rm <path>` | XcodeRM | Removes files and directories from the Xcode project structure and optionally deletes the underlying files from the filesystem. | `--delete-files` `--recursive` |
| `xc read <filePath>` | XcodeRead | Reads the contents of a file within the Xcode project organization. | `--limit` `--offset` |
| `xc edit <filePath> <oldString> <newString>` | XcodeUpdate | Edits files in the Xcode project by replacing text content. | `--replace-all` |
| `xc write <filePath> <content>` | XcodeWrite | Creates or overwrites files with content in the Xcode project. | — |

## Build settings, entitlements and Info.plist

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc add-entitlement <targetName> <entitlementKey> <entitlementValueType>` | AddEntitlement | Add a new entitlement to the project's entitlements file. | `--entitlement-dictionary-items` `--entitlement-value` `--entitlement-value-items` `--project-path` |
| `xc add-info-plist <targetName> <infoPlistKey> <infoPlistValueType>` | AddInfoPlist | Add or update an Info.plist key in the project. | `--info-plist-dictionary-items` `--info-plist-value` `--info-plist-value-items` `--project-path` |
| `xc get-file-compiler-flags <targetName> <filePath>` | GetFileCompilerFlags | Gets the additional per-file compiler flags for a single source file in a specific Xcode target — the same value shown in the Compiler Flags column of Target > Build Phases > Compile Sources. | `--project-path` |
| `xc settings <targetName>` | GetTargetBuildSettings | Get all the Xcode build setting for a specified Xcode project target. | `--project-path` |
| `xc update-file-compiler-flags <targetName> <filePath>` | UpdateFileCompilerFlags | Updates, appends or deletes the additional per-file compiler flags for a single source file in a specific Xcode target — the same value shown in the Compiler Flags column of Target > Build Phases > Compile Sources. | `--append-value` `--compiler-flags` `--project-path` |
| `xc update-target-build-setting <targetName> <buildSettingName>` | UpdateTargetBuildSetting | Updates, appends or deletes the named build setting for the specified Xcode project target. | `--append-value` `--build-setting-value` `--project-path` |

## Localization

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc localization-planner <targetLocaleIdentifier>` | LocalizationPlanner | Ensures the project is in a state where translations can be added. | — |
| `xc string-catalog-context <filePath> <stringKey> <targetLocaleIdentifier>` | StringCatalogContext | Returns context and the source language value for a given string in the String Catalog. | — |
| `xc string-catalog-edit <filePath> <stringKey> <targetLocaleIdentifier>` | StringCatalogEdit | Inserts a translation for a given locale into a String Catalog. | `--string-set-translation` `--template-translation` `--translation` `--variation-translation` |
| `xc string-catalog-read <filePath> <targetLocaleIdentifier>` | StringCatalogRead | Returns string keys grouped by translation state for the requested locale. | `--key-limit` `--offset` `--requested-state` |

## Crashes and field performance

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc get-crash-issue-logs <signature_name>` | GetCrashIssueLogs | Get detailed crash logs, expert triage knowledge, and actionable recommendations for a specific crash signature. | `--app_version` `--bundle_id` `--is_beta` `--platform` |
| `xc get-field-performance-issue-logs <app_version> <signature_name> <diagnostic_type>` | GetFieldPerformanceIssueLogs | Get detailed logs, performance data, expert triage knowledge, and actionable recommendations for specific field performance issue. | `--bundle_id` `--is_beta` `--platform` |
| `xc get-top-crash-issues` | GetTopCrashIssues | Retrieve the top crash signatures for an app from Apple's crash reporting service. | `--app_version` `--bundle_id` `--count` `--is_beta` `--platform` |
| `xc get-top-field-performance-issues <diagnostic_type>` | GetTopFieldPerformanceIssues | Analyze app performance and identify performance regressions across different diagnostic types. | `--app_version` `--bundle_id` `--is_beta` `--platform` |

## Documentation

| Command | Tool | What it does | Optional flags |
|---|---|---|---|
| `xc docs <query>` | DocumentationSearch | Searches Apple Developer Documentation using semantic matching. | `--frameworks` |
