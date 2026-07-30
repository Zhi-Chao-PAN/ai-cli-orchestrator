# Bounded AIW work order

Use this UTF-8 file with the provider-neutral `aiw run` command. The dispatcher
does not infer a route from this text; the caller must select a configured
route, profile, or worker.

## Objective

State one concrete outcome and the evidence that will prove it.

## Scope

- Working directory:
- Files or modules allowed:
- Files or systems forbidden:
- Repository/worktree identity:

## Capabilities and policy

- Selector: `route` / `profile` / `worker`:
- Required capabilities: `text.reason` / `context.long` /
  `workspace.read` / `workspace.write` / `quota.read`:
- Mode: `read` / `write` (write requires explicit caller authorization):
- Fallback: profile policy only; no manual provider chaining:
- Model: use the model pinned by the selected worker definition; do not put
  credentials or provider-specific overrides in this work order.

## Constraints

- Preserve:
- Do not:
- Dependencies or network access allowed:
- Credential handling: never read, print, move, or request secrets:
- Compatibility or security requirements:

## Acceptance

- Commands that must pass:
- Expected artifact or behavior:
- Required diff/review evidence:
- Required summary of files changed, tests run, and unresolved risks:

## Execution budget

- Worker timeout budget (seconds):
- Outer caller timeout (at least worker timeout + 30 seconds):
- Maximum prompt bytes (default 1 MiB):

## Reporting

Return structured, concise evidence. State whether the objective was met, list
all changed paths, include test/acceptance output, and call out any partial
write or unresolved uncertainty. A worker's self-reported success is not final
acceptance. Native stdout may be structured JSON or raw text; do not request or
rely on provider stderr because public diagnostics deliberately withhold it. If
the result reports `output_limit`, reduce or split the work order and inspect
the local boundary rather than manually retrying a partial write.
