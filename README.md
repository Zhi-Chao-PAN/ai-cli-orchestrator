# AI CLI Orchestrator

AI CLI Orchestrator (`aiw`) is a provider-neutral Windows PowerShell dispatcher
that turns supported local AI CLIs into bounded, named workers. Codex or a
human remains responsible for task boundaries, reviewing changes, and final
acceptance.

AIW stores no provider credentials. Each CLI continues to use its own native
login or credential store.

Chinese documentation: [README.zh-CN.md](README.zh-CN.md).

## Why AIW

Paid plans, local accounts, and model preferences differ. AIW therefore ships
no universal provider order and does not guess a route from prompt text. You
declare local workers, put them in ordered profiles, and map explicit task
routes to capability requirements. Capability checks always happen before
profile priority.

The maintainer's subscription mix is retained only as an optional
[showcase](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/README.md). It is never installed or selected by
default.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- One or more independently installed and authenticated CLIs supported by the
  adapter catalog
- Git is recommended when a write task is isolated in a worktree

## Install

Clone or extract a release, then run:

~~~powershell
Set-Location path\to\ai-cli-orchestrator
.\install.ps1 -AddToPath -InstallCodexSkill
~~~

Restart terminals after changing the user `PATH`. Without changing `PATH`, call
the installed launcher directly:

~~~powershell
& (Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1') catalog -Json
~~~

A fresh v0.3 install does not copy a personal configuration. An upgrade
preserves an existing schema v1 or v2 user configuration.

To upgrade an existing AIW-owned installation after reviewing the destination:

~~~powershell
.\install.ps1 -Force -AddToPath -InstallCodexSkill
~~~

`-Force` accepts only an installation with a valid AIW ownership marker. It
preserves `$env:USERPROFILE\.aiw\config.json`; when replacing a foreign Codex
skill, the installer creates a timestamped backup.

## Provider-neutral first run

Inspect the reviewed adapters without contacting a model service:

~~~powershell
aiw catalog -Json
~~~

Create an explicit deny-by-default v2 config, then add only workers you use:

~~~powershell
$configDirectory = Join-Path $env:USERPROFILE '.aiw'
New-Item -ItemType Directory -Force $configDirectory
Copy-Item .\config.example.json (Join-Path $configDirectory 'config.json')

aiw config -Action validate -ConfigPath (Join-Path $configDirectory 'config.json') -Json
~~~

`config.example.json` intentionally contains empty `workers`, `profiles`, and
`routes` objects. See
[`examples/profiles/supported-clis.example.json`](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/profiles/supported-clis.example.json)
for independent single-adapter examples; copy only the definitions that match
your machine and replace placeholder model values.

After defining a worker, profile, or route:

~~~powershell
aiw run -Worker  '<worker-id>'  -PromptFile 'C:\work\task.md' -Mode read -WorkingDirectory 'C:\repo' -Json
aiw run -Profile '<profile-id>' -PromptFile 'C:\work\task.md' -Mode read -WorkingDirectory 'C:\repo' -Json
aiw run -Route   '<route-id>'   -PromptFile 'C:\work\task.md' -WorkingDirectory 'C:\repo' -Json
~~~

Use a UTF-8 `PromptFile` for every non-trivial or multiline work order. Start
from [WORK_ORDER_TEMPLATE.md](WORK_ORDER_TEMPLATE.md) to define the objective,
allowed scope, forbidden changes, and acceptance commands.

## Concepts

| Concept | Meaning |
| --- | --- |
| Adapter | Reviewed code shipped with AIW that translates one stable request into one specific CLI invocation. Configuration cannot define adapters or shell commands. |
| Worker | A named local instance of an adapter with a model, executable path, native profile reference, and a capability subset. |
| Profile | An ordered list of worker IDs plus a bounded read-only fallback policy. The order belongs to the user, not AIW. |
| Route | An explicit task class that selects one profile and declares required capabilities and allowed modes. Routes do not classify prompts. |

Models belong to worker definitions rather than the `run` call. This keeps a
named worker reproducible and lets two accounts or models of the same CLI be
configured independently.

## Reviewed adapter catalog

| Adapter ID | CLI | Maximum reviewed capabilities | Prompt transport | Official source |
| --- | --- | --- | --- | --- |
| `claude-code/v1` | Claude Code, including compatible endpoints isolated in native Claude profiles | `text.reason`, `workspace.read`, `workspace.write` | standard input | [Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage) |
| `antigravity/v1` | Google Antigravity CLI (`agy`) | `text.reason`, `context.long`, `workspace.read`, `workspace.write` | controlled temporary file | [Antigravity CLI documentation](https://www.antigravity.google/docs/cli/using) |
| `minimax-cli/v1` | MiniMax CLI (`mmx`) | `text.reason`, `quota.read` | controlled temporary JSON file | [MiniMax CLI guide](https://platform.minimaxi.com/docs/token-plan/minimax-cli) |

These links define the upstream tools; the adapter implementation and tests in
this repository define AIW's supported surface. A new provider requires a
reviewed source adapter in a release. JSON cannot supply a command, argument
template, script, hook, environment map, or remote adapter URL.

Adapter-specific v2 settings are deliberately small:

- `claude-code/v1`: optional `configDirectory` for a trusted native profile;
- `antigravity/v1`: no configuration-directory override; AIW always keeps the
  native sandbox enabled and registers only the canonical workspace and
  controlled work-order directory;
- `minimax-cli/v1`: required `region` (`cn` or `global`) and optional
  `configDirectory`, mapped to `MMX_CONFIG_DIR`. AIW compiles the service
  endpoint for the selected region and accepts no arbitrary endpoint URL.

MiniMax has no reviewed workspace capability and cannot satisfy a repository
read or write route.

### Output decoding and diagnostics

AIW treats worker stdout as untrusted payload. It decodes valid JSON stdout
into a structured `output` value and otherwise returns raw stdout text. Claude
Code and MiniMax adapters request JSON from their native CLIs; Antigravity
requests text. Those requests are not a JSON-only protocol requirement, and
invalid JSON stdout is not converted into a protocol failure.

AIW never parses stderr as provider output and does not publish provider stderr
in a result envelope. When a worker writes stderr, public `diagnostics` uses a
generic withheld message; use the structured `failureKind`, `error`, and
attempt metadata for automation rather than relying on provider diagnostics.

## Configuration schema v2

The neutral shape is:

~~~json
{
  "schemaVersion": 2,
  "defaultRoute": null,
  "defaultProfile": null,
  "workers": {},
  "profiles": {},
  "routes": {}
}
~~~

Only one of `defaultRoute` and `defaultProfile` may be set. Without an explicit
selector or configured default, `run` returns `SELECTION_REQUIRED`; there is no
hidden provider preference.

Configuration lookup is explicit `-ConfigPath`, then `AIW_CONFIG_PATH`, then
the user-level AIW path. AIW never auto-loads repository-local configuration.
Relative paths in an explicit config resolve from that config's directory.
An explicit v2 file, including an empty one, disables implicit worker
discovery. Discovery without a config is in-memory, does not create a file,
does not contact a model, and does not invent credentials, models, profiles,
routes, or priority.

Configuration is optional for `catalog` and schema-2 inventory. Without a
config, `status -OutputSchema 2` and `doctor -OutputSchema 2` can report
approved executables found on `PATH`, but they choose no default worker,
profile, route, model, or MiniMax region. An explicitly selected discovered
worker may run only when its reviewed capability is sufficient; profiles,
routes, and generic MiniMax execution require explicit v2 configuration.

Validate before every rollout:

~~~powershell
aiw config -Action validate -ConfigPath 'C:\path\to\config.json' -Json
~~~

Validation rejects unknown fields, secret-like names, command or argument
fields, capability escalation, unsupported adapters, broken references,
unsafe launchers, arbitrary endpoints, excessive size/depth/counts, and routes
that default to write. Never place a key, token, cookie, password, or
authorization value in AIW configuration.

Schema-2 inventory and doctor calls are local probes, not authentication or
service checks. For a configured worker, `doctor -OutputSchema 2` resolves the
approved executable and, where `configDirectory` is supported, checks only
whether that native profile directory exists. It does not open profile files,
run hooks, inspect credentials, or contact a provider. A missing selected
profile fails before provider start with `PROFILE_DIRECTORY_INVALID`; a doctor
result where all enabled configured workers are unavailable uses
`CONFIGURED_WORKERS_UNAVAILABLE`.

## Selection and fallback

Resolution is deterministic:

1. Resolve the selected worker, profile, route, or configured default.
2. Combine route, mode, and caller-added capability requirements.
3. Remove disabled, unavailable, launcher-incompatible, and
   capability-ineligible workers.
4. Preserve the remaining profile order and run inside one total timeout
   budget.

`read` is a side-effect ceiling, not an implicit `workspace.read` request. A
stateless route can require only `text.reason`; a repository route must name
`workspace.read` explicitly. Write always requires the caller to pass
`-Mode write`, even if the route allows it.

Fallback is intentionally narrow:

- `-Worker` and `-NoFallback` never cross to another worker;
- only failure kinds listed in the profile's read-only fallback policy are
  eligible;
- `permission_denied`, policy/config/capability failures, unsafe launchers, and
  wrapper errors never fall back;
- timeout fallback is opt-in, read-only, and requires confirmed process-tree
  termination plus remaining budget;
- after any write worker starts, no second worker starts.

Static capability skips are not attempts. They remain visible in the schema v2
result so selection can be audited.

## Safety and trust boundaries

- Schema-v2 work orders are bounded to 1 MiB; callers may narrow the limit.
  The legacy facade retains its historical 16 MiB parameter range solely for
  v0.2 compatibility.
- Prompt content does not appear in provider argv or arbitrary environment
  values.
- `.exe` and `.ps1` launch through fixed paths and argument arrays. `.cmd` and
  `.bat` fail closed except the exact reviewed MiniMax npm shim, whose prompt
  remains in a temporary file.
- Standard output and standard error remain separate. Valid JSON stdout becomes
  structured output; other stdout remains raw text. Provider stderr is neither
  parsed nor published, and a non-empty stderr stream yields only a generic
  withheld diagnostic.
- Each output stream is bounded to 16 MiB. Timeouts and output overflow
  terminate the Windows process tree and return structured evidence. An
  overflow is a v2 `output_limit` failure with `error.code` `OUTPUT_LIMIT`,
  `outputLimitExceeded: true`, exit code `1`, and no captured provider output.
- Controlled temporary directories are uniquely named, namespace-checked, and
  cleaned after use.
- A post-execution environment or temporary-artifact cleanup failure preserves
  the completed child's exit code in `attempts`, sets `cleanupFailed: true`,
  returns `wrapper_error`, and never triggers fallback.
- Permission bypasses and global file grants are not acceptable fixes.

The user-level AIW config, the user's `PATH`, installed provider binaries, and
provider-native profiles are trusted local dependencies. Native profiles may
contain hooks or plugins with the user's authority; AIW does not sandbox a
malicious profile or attest a replaced binary. Resolved paths and provenance
should therefore be reviewed with inventory/doctor output.

For concurrent writers, use one Git worktree per worker. Never retry or hand a
partial write to another model before inspecting the existing tree.

See [SECURITY.md](SECURITY.md) for the complete boundary and disclosure policy.

## Result contracts

New commands (`run`, `catalog`, and `config`) use a schema v2 envelope with
stable selection, attempt, skip, timeout, failure, output, and diagnostic
fields. Important execution families include `permission_denied`,
`authentication`, `quota_or_rate_limit`, `process_exit`, `timeout`,
`stream_drain_timeout`, `output_limit`, and `wrapper_error`.

Every public schema-v2 result includes the top-level `productVersion` from the
repository's single `version.json` source. Schema-v1 compatibility envelopes
remain unchanged and do not gain this field.

Exit codes are `0` for success, `1` for a final started-worker failure, `2` for
request/config/selection/preflight failure, `124` for final process timeout,
and `125` for final stream-drain timeout. `output_limit` is a started-worker
failure and therefore uses public exit code `1`. Provider child exit codes
remain in attempt records. A worker's success message is transport evidence,
not final acceptance.

## v0.2 compatibility and migration

The legacy `status`, `doctor`, `ark`, `agent`, `google`, `minimax`, and `quota`
commands and schema v1 envelopes remain supported in v0.3 with no removal date.
Their historical defaults exist only inside the compatibility facade; they are
not v2 routing defaults.

One deliberate v0.3 security hardening applies to legacy results: raw provider
stderr is replaced by a generic withheld diagnostic. This prevents echoed work
orders or credential-like text from escaping through schema-v1 diagnostics;
the legacy envelope shape, defaults, command behavior, and exit behavior remain
golden-tested.

A schema v1 config remains usable by that compatibility facade. Generic `run`
and schema-2 route/profile selection do not silently normalize a v1 file:
migrate it explicitly first. `status` or `doctor` with `-OutputSchema 2`
reports legacy provenance and migration guidance without rewriting the source
file or manufacturing v2 workers.

To create an editable v2 file without changing the v1 source:

~~~powershell
aiw config -Action migrate `
  -ConfigPath 'C:\path\to\v1-config.json' `
  -Destination 'C:\path\to\new-v2-config.json' `
  -Json
~~~

Migration fails if the destination exists, writes no credentials, and never
modifies the source. Validate the destination, inspect the generated workers,
then add your own profiles and routes. Existing installations are not migrated
silently.

## Optional maintainer showcase

[`examples/showcases/maintainer-paid-plans.example.json`](https://github.com/Zhi-Chao-PAN/ai-cli-orchestrator/blob/main/examples/showcases/maintainer-paid-plans.example.json)
records one maintainer's Google → MiniMax → Ark Coding → Ark Agent → metered
DeepSeek strategy. It is demonstration data, not a recommendation or default.
Repository routes still filter MiniMax for lack of workspace capability, and
the two Ark Coding model workers demonstrate how model preference becomes
profile data.

The showcase's Ark and DeepSeek workers rely on isolated native Claude Code
profiles. Refer to the providers' current official integration documentation,
including [Volcengine Ark](https://console.volcengine.com/ark/region:cn-beijing/docs/82379/1928261?lang=zh)
and [DeepSeek's Anthropic API guide](https://api-docs.deepseek.com/guides/anthropic_api/),
and never copy credentials or endpoint URLs into AIW JSON. Plans, model names,
and quotas can change; review every value before adapting the example.

## Verify changes

~~~powershell
.\tests\ai-workers.tests.ps1
.\ai-workers.ps1 catalog -Json
.\ai-workers.ps1 config -Action validate -ConfigPath .\config.example.json -Json
~~~

Run deterministic tests before any real-service smoke. A release acceptance
also requires PowerShell 5.1 and 7 coverage plus a separate fresh Codex task
that verifies installed hashes, global skill discovery, and one bounded
read-only call with explicit `COLD_START_PASS` or evidence-backed failure.

## Uninstall

The uninstaller is guarded by an installation marker and preserves user
configuration by default:

~~~powershell
.\uninstall.ps1
~~~

Use the skill/config removal switches only when that deletion is intended.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for adapter admission and test
requirements. Responsible disclosure guidance is in
[SECURITY.md](SECURITY.md).

MIT. See [LICENSE](LICENSE).
