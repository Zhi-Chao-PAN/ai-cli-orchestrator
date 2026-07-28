---
name: dispatch-ai-workers
description: Route bounded coding, debugging, testing, review, research, and stateless reasoning work from Codex to locally installed prepaid AI CLI workers through the secret-free aiw dispatcher. Use when a task can be delegated safely, when the user asks to conserve GPT quota or use Gemini, MiniMax, Ark Coding, or Ark Agent plans, or when an independent model review would improve confidence. Do not use for tiny, highly coupled, sensitive, or interaction-heavy tasks where direct Codex work is more reliable.
---

# Dispatch AI Workers

Act as planner and acceptance authority. Delegate only bounded work, then inspect
the actual artifacts and run local verification yourself.

## Locate the dispatcher

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
~~~

If no entry point is found, do not improvise provider commands or request
credentials. Explain that aiw is not installed and point to the project
installer.

Run doctor or status with JSON before a meaningful dispatch. Treat this only
as local configuration evidence; a real bounded read task proves live
availability.

## Select a worker

Apply capability and safety constraints before priority:

1. google — Gemini through Antigravity; use for independent review and
   long-context analysis. It remains sandboxed and workspace-scoped.
2. minimax — stateless text/reasoning only; never request repository writes.
3. ark — Coding Plan; default GLM-5.2, with Kimi-K2.7-Code only as an
   explicit second opinion or failed read-only fallback.
4. agent — Ark Agent Plan's separate quota/profile for agent-oriented work.
5. A metered provider only when separately configured and authorized.

Skip delegation when the task is tiny, needs continuous Codex judgement, has
secrets or destructive actions, or would cost more to verify than to do
directly. When a substantial work task could reasonably have been delegated
but is deliberately kept local, state the reason in one sentence.

## Dispatch workflow

1. Inspect the live repository and its dirty state.
2. Write a UTF-8 work-order file with objective, allowed paths, forbidden
   changes, mode, and acceptance commands. Use PromptFile for all non-trivial
   tasks.
3. Default to read mode; use write only with clear approved scope.
4. Use JSON, and give the outer caller at least TimeoutSeconds plus 30 seconds
   so the dispatcher can return structured timeout evidence.
5. Inspect diffs, test locally, and report verified results. Worker text alone
   is never acceptance.

~~~powershell
& $aiw google  -PromptFile 'C:\tmp\review.md' -Mode read  -WorkingDirectory 'C:\repo' -Json
& $aiw minimax -PromptFile 'C:\tmp\design.md' -Mode read  -WorkingDirectory 'C:\repo' -Json
& $aiw ark     -PromptFile 'C:\tmp\write.md'  -Mode write -WorkingDirectory 'C:\repo' -Json
& $aiw agent   -PromptFile 'C:\tmp\agent.md'  -Mode read  -WorkingDirectory 'C:\repo' -Json
~~~

## Failure and safety protocol

Inspect ok, exitCode, timedOut, readTimedOut, failureKind, attempts, output,
and diagnostics.

- permission_denied: verify the scoped work order and working directory; never
  grant global file access or bypass permissions.
- timeout: narrow the task or deliberately raise both timeout budgets; do not
  blindly retry a partially completed write.
- authentication or quota_or_rate_limit: use the next compatible prepaid
  worker, without exposing or moving credentials.
- stream_drain_timeout, process_exit, or wrapper_error: preserve the structured
  evidence and diagnose the local dispatcher or CLI first.

Never place API keys in work orders, source files, logs, or worker arguments.
Never dispatch two writers to one checkout; use separate Git worktrees. Never
retry a partial write with another model before reviewing the current tree.
