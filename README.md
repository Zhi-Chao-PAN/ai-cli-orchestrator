# AI CLI Orchestrator

AI CLI Orchestrator (aiw) is a Windows PowerShell dispatcher for using
existing AI CLI subscriptions as bounded workers. It keeps Codex or a human in
charge of planning and acceptance while routing suitable work to Gemini,
MiniMax, Ark Coding, and Ark Agent.

It stores no provider credentials. Each official CLI continues to use its own
native login or credential store.

Chinese documentation: see README.zh-CN.md.

## What it provides

| Command | Default use | Default model |
| --- | --- | --- |
| ark | repository coding, tests, and debugging | glm-5.2 |
| agent | work requiring the separate Ark Agent profile | ark-code-latest |
| google | independent review and long-context analysis | gemini-3.6-flash-high |
| minimax | stateless reasoning and text work | MiniMax-M3 |
| quota | MiniMax quota inspection | n/a |
| status / doctor | local non-secret diagnostics | n/a |

The default routing order is Google, MiniMax, Ark Coding, Ark Agent, then any
separately configured metered fallback. Capability constraints come first:
MiniMax never receives repository write access.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- One or more provider CLIs installed and authenticated independently:
  Claude Code for Ark, Antigravity for Google, and mmx for MiniMax
- Git is recommended for writer isolation through worktrees

## Install

Clone or extract a release, then run:

~~~powershell
Set-Location path\to\ai-cli-orchestrator
.\install.ps1 -AddToPath -InstallCodexSkill
~~~

The installer copies the application to a per-user location, creates a
secret-free configuration file only when none exists, and can install the
Codex skill. Restart terminals after changing the user PATH.

Without adding PATH, call the installed launcher directly:

~~~powershell
& (Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1') doctor -Json
~~~

## Quick start

~~~powershell
aiw status -Json
aiw doctor -Json

aiw google -Prompt 'Review this repository for the three highest-risk defects.' -Mode read -Json
aiw minimax -PromptFile 'C:\tmp\design.md' -Mode read -Json
aiw ark -PromptFile 'C:\tmp\implementation.md' -Mode write -WorkingDirectory 'C:\repo' -Json
~~~

Use PromptFile for every non-trivial or multiline work order. The supplied
WORK_ORDER_TEMPLATE.md defines a bounded objective, scope, constraints, and
acceptance commands.

## Configuration

Copy config.example.json to the per-user aiw configuration directory, then edit
only non-secret values:

~~~powershell
$configDirectory = Join-Path $env:USERPROFILE '.aiw'
New-Item -ItemType Directory -Force $configDirectory
Copy-Item .\config.example.json (Join-Path $configDirectory 'config.json')
~~~

Precedence is explicit ConfigPath, AIW_CONFIG_PATH, then the per-user config.
Executable paths can also be supplied through AIW_ARK_PATH, AIW_AGENT_PATH,
AIW_GOOGLE_PATH, or AIW_MINIMAX_PATH. Relative paths in the config are resolved
relative to the config file. Do not place tokens, passwords, or API keys in
this file.

## Safety model

- Read mode is the default. Write mode must be explicit.
- Work orders are limited to 1 MiB by default.
- Ark and Agent receive work orders on standard input, not as command-line
  arguments. MiniMax uses a short-lived UTF-8 JSON message file.
- Google receives a short-lived UTF-8 work-order file in a uniquely named
  temporary directory; the Google workspace and that directory are both
  explicitly registered and the terminal sandbox remains enabled.
- Standard output and standard error are kept separate. Only stdout is parsed
  as provider JSON; sanitized stderr appears as diagnostics.
- Timeouts terminate the Windows process tree and return structured evidence.
- Batch-file workers are rejected except for the npm-provided MiniMax wrapper.
  That exception accepts only validated model and HTTPS endpoint values, while
  prompt text remains in a temporary message file. The public launcher is
  aiw.ps1.
- Never use permission bypasses or global file grants to solve a worker
  permission failure.

For concurrent writers, use one Git worktree per worker. Never retry a partial
write with another model before inspecting the current tree.

## Output contract

JSON commands return an envelope with schemaVersion, ok, command, worker,
model, mode, exitCode, timedOut, readTimedOut, durationMs, failureKind,
attempts, output, and diagnostics.

Important failure kinds include timeout, stream_drain_timeout,
permission_denied, authentication, quota_or_rate_limit, process_exit, and
wrapper_error. A worker reporting success is transport evidence, not final
acceptance.

## Verify changes

~~~powershell
.\tests\ai-workers.tests.ps1
.\ai-workers.ps1 status -Json
.\ai-workers.ps1 doctor -Json
~~~

## Uninstall

The uninstaller is guarded by an installation marker and preserves user
configuration by default:

~~~powershell
.\uninstall.ps1
~~~

Use RemoveCodexSkill or RemoveUserConfig only when that deletion is intended.

## Contributing and security

See CONTRIBUTING.md for development conventions and SECURITY.md for responsible
disclosure and hardening expectations.

## License

MIT. See LICENSE.
