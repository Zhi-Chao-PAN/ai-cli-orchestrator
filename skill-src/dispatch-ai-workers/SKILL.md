---
name: dispatch-ai-workers
description: Route bounded coding, debugging, testing, review, research, and stateless reasoning work from Codex to configured local AI CLI workers through the secret-free aiw dispatcher. Use when a task can be delegated safely or an independent model review would improve confidence. Do not use for tiny, highly coupled, sensitive, destructive, or interaction-heavy tasks where direct Codex work is more reliable.
---

# Dispatch AI Workers

Act as planner and acceptance authority. Delegate only bounded work, then
inspect the actual artifacts and run local verification yourself. The worker
reports transport evidence; it does not approve its own changes.

## Decide whether to delegate

Before dispatching, consider whether the task has a clear objective, bounded
paths, explicit mode, independent acceptance commands, and enough context to
avoid repeated clarification. Keep the task in Codex when it is tiny, tightly
coupled to this conversation, sensitive, destructive, permission-sensitive,
or more expensive to verify than to complete directly. If a work task could
reasonably be delegated but you keep it local, tell the user why in one short
sentence.

Never put secrets in a work order. Do not dispatch concurrent writers into one
checkout; use separate Git worktrees and inspect any partial write before
another worker can act.

## Locate and validate the dispatcher

Resolve the entry point in this order:

~~~powershell
$aiw = $env:AIW_ENTRYPOINT
if ([string]::IsNullOrWhiteSpace($aiw)) {
  $command = Get-Command aiw -ErrorAction SilentlyContinue
  if ($command) { $aiw = $command.Source }
}
if ([string]::IsNullOrWhiteSpace($aiw)) {
  $candidate = Join-Path $env:LOCALAPPDATA 'aiw\app\ai-workers.ps1'
  if (Test-Path -LiteralPath $candidate) { $aiw = $candidate }
}
if ([string]::IsNullOrWhiteSpace($aiw)) {
  throw 'aiw is not installed; use the repository installer.'
}
~~~

Before meaningful work, run local, non-billable inventory. Validate a config
only when an explicit v2 config path is already selected:

~~~powershell
& $aiw catalog -Json
& $aiw status -OutputSchema 2 -Json
& $aiw doctor -OutputSchema 2 -Json

if (-not [string]::IsNullOrWhiteSpace($configPath)) {
  & $aiw config -Action validate -ConfigPath $configPath -Json
}
~~~

When available, use schema-2 `status` or `doctor` output to inspect configured
workers, routes, resolved launchers, and provenance. Do not print the config
file or secret-bearing native profile contents. Doctor only checks a supported
configured native-profile directory for existence; it does not open that
profile, run hooks, inspect credentials, or prove a live login. If no v2 config
exists, do not invent a provider order. An explicit discovered worker can be
used only after capability review; routes, profiles, and MiniMax execution need
an explicit v2 config.

A schema v1 config remains supported by legacy aliases. Do not feed it to
generic `run` and assume it will normalize: create a new destination with
`config -Action migrate`, validate it, and review its workers before dispatch.

## Select by capability and user policy

AIW v2 has no universal provider priority. Resolve selectors in this order:

1. Use the route explicitly named by the user or repository instructions.
2. Otherwise use a configured route whose declared requirements match the task.
3. Otherwise use an explicitly named profile.
4. Use a named worker only when the user asks for that exact instance or when a
   one-worker profile makes the choice unambiguous.
5. If no selector/default is configured, stop with `SELECTION_REQUIRED` and
   explain which route/profile is needed; never silently choose a provider.

Classify the task's needed capabilities yourself (for example
`text.reason`, `context.long`, `workspace.read`, `workspace.write`, or
`quota.read`) and pass additional requirements with `-RequireCapability` when
needed. `read` is a side-effect ceiling, not an implicit workspace capability;
a repository route must explicitly require `workspace.read`. AIW checks
capabilities before it considers profile order. It never classifies prompt
content on its own.

Worker models belong to worker definitions. Do not add provider-specific
`-Model` flags to a v2 call. The repository's maintainer-plan showcase is
example data only; it is never a skill default.

## Create a bounded work order

Use a UTF-8 `-PromptFile` for all non-trivial or multiline tasks. Include:

- objective and non-goals;
- exact workspace and allowed paths;
- read/write mode and forbidden operations;
- constraints on dependencies, credentials, and external calls;
- acceptance commands and expected evidence;
- an instruction to summarize files changed, tests run, and unresolved risks.

Default to read mode. Write requires explicit user authorization and
`-Mode write`. Give the outer caller at least `TimeoutSeconds + 30` seconds so
AIW can terminate descendants and return structured timeout evidence.

## Dispatch commands

Use the stable v2 interface and JSON output:

~~~powershell
& $aiw run -Route $route `
  -PromptFile $promptFile `
  -Mode read `
  -WorkingDirectory $workingDirectory `
  -TimeoutSeconds 600 `
  -Json

& $aiw run -Profile $profile `
  -PromptFile $promptFile `
  -Mode read `
  -WorkingDirectory $workingDirectory `
  -Json

& $aiw run -Worker $worker `
  -PromptFile $promptFile `
  -Mode write `
  -WorkingDirectory $worktree `
  -NoFallback `
  -Json
~~~

Use exactly one of `-Worker`, `-Profile`, and `-Route`. Omit all selectors only
when an explicit v2 `defaultRoute` or `defaultProfile` is configured.

The legacy aliases (`status`, `doctor`, and provider-specific v0.2 commands)
remain for compatibility, but new skill dispatch should use `run`, `catalog`,
and `config` so the skill remains provider-neutral.

## Inspect result and accept independently

Inspect at least:

`ok`, `exitCode`, `selection`, `skipped`, `attempts`, `timedOut`,
`readTimedOut`, `outputLimitExceeded`, `terminationSucceeded`, `failureKind`,
`output`, and generic withheld `diagnostics`.

AIW decodes valid JSON stdout and otherwise returns raw stdout text. Never
interpret provider stderr as evidence: it is intentionally withheld from public
diagnostics. `output_limit` means either stdout or stderr exceeded the 16 MiB
capture cap; it maps to `OUTPUT_LIMIT`, terminates the process tree, and leaves
no captured provider output to inspect.

Treat static capability skips separately from started attempts. Review every
file change, diff, test result, and acceptance command locally. A worker's
claim that it fixed a bug, passed a test, or used the requested model is not
final acceptance.

## Failure and fallback protocol

- `permission_denied`: verify the bounded work order and workspace; never add
  global permissions, use a bypass flag, or elevate privileges.
- `authentication` or `quota_or_rate_limit`: let the selected profile's
  allowlist handle a read-only fallback, or report the failure. Never move or
  expose credentials.
- `timeout`: preserve evidence; fallback is allowed only when the profile
  explicitly opts in, the process tree is confirmed terminated, mode is read,
  and the shared deadline has time remaining.
- `config_invalid`, `capability_denied`, `launcher_unsafe`, `policy_denied`,
  `profile_directory_invalid`, `process_start_failed`, `stream_drain_timeout`,
  `output_limit`, `wrapper_error`, and permission failures never trigger
  fallback.
- A started write attempt never launches another worker. Inspect the tree first.

Do not manually chain provider commands to simulate fallback; doing so bypasses
the shared deadline, capability checks, and audit envelope.

## Security boundaries

AIW configuration may select only adapters compiled into the installed release.
It cannot define shell commands, argument templates, scripts, hooks, arbitrary
environment maps, credentials, or arbitrary provider endpoints. The user's
`PATH`, binaries, and native provider profiles remain trusted local
dependencies and must be reviewed as such.

Never use `read_file(*)`, `--dangerously-skip-permissions`, global file grants,
or credential values in prompts, arguments, logs, or reports. If a provider
cannot satisfy the requested capability safely, keep the work in Codex or
report the bounded failure.
