# Security policy

AI CLI Orchestrator is a bounded dispatcher, not a credential broker, binary
attestation system, or security boundary against a malicious local user.

## Report a vulnerability

Do not publish provider credentials, private work orders, local configuration
contents, or an exploitable proof of concept in a public issue. Use the
repository host's private security-report channel or ask a maintainer for a
private contact.

Include:

- the affected AIW command and version;
- Windows and PowerShell versions;
- the adapter ID and upstream CLI version;
- minimal, non-secret reproduction steps;
- the redacted structured result envelope;
- whether a worker process started and whether tree termination succeeded.

Obtain the installed version from the top-level `productVersion` returned by
`aiw catalog -Json`. New ownership markers record the same value; do not attach
marker files or provider-native profiles to a public report.

## Security goals

AIW is designed to:

- keep provider credentials in provider-native stores;
- validate the complete request and config before process creation;
- expose only reviewed adapters compiled into the installed release;
- narrow workspace and tool permissions by explicit read/write mode and
  declared capabilities;
- transport prompt content without placing it in provider argv;
- keep stdout and stderr separate, bound capture size, withhold provider stderr
  from public diagnostics, and terminate process trees on timeout or when a
  worker root returns;
- prevent automatic cross-worker retries after a write worker starts;
- fail closed when a launcher or configuration surface is not reviewed.

## Trusted local boundaries

The following already execute or influence execution with the user's local
authority and must be treated as trusted dependencies:

- the user-level AIW configuration selected explicitly, through
  `AIW_CONFIG_PATH`, or from the documented user location;
- the user's `PATH` and any explicit executable path;
- installed provider binaries and their update mechanisms;
- provider-native profile/config directories, including their hooks, plugins,
  MCP servers, and other executable extensions;
- the current Windows account and filesystem permissions.

AIW validates executable basenames and launcher extensions to prevent adapter
confusion; it does not authenticate a replaced binary. Fixed tool flags do not
neutralize malicious code loaded by a provider-native profile. Use isolated,
reviewed native profiles for compatible endpoints.

AIW never auto-loads configuration from the working repository. A malicious
repository can still influence an agent through the files the selected worker
is explicitly allowed to read, so work orders, repository trust, and output
review remain necessary.

## Configuration boundary

Schema v2 is policy data, not executable configuration. It may select only
adapters shipped with AIW and may only narrow their reviewed capabilities.

The validator rejects:

- keys, tokens, passwords, cookies, credentials, authorization fields, and
  other secret-like property names;
- `command`, `args`, `arguments`, `template`, `script`, `shell`, `hook`, and
  arbitrary `env` fields at any depth;
- unknown top-level, worker, profile, route, and adapter-setting fields;
- arbitrary provider endpoint URLs;
- unsupported adapters, executable names, launcher extensions, malformed model values,
  capabilities, modes, and broken references;
- route defaults that request write;
- files, nesting, object counts, and error counts beyond documented limits.

MiniMax exposes only the reviewed `cn` and `global` region enum; the adapter
maps each value to a compiled endpoint. Antigravity exposes no profile-directory
override. Claude Code may reference a native `configDirectory`, which is an
explicit trusted dependency rather than credential data.

A legacy schema v1 config remains available to its frozen compatibility aliases,
but generic `run` and v2 route/profile selection require an explicit,
non-destructive `config migrate` result. AIW never rewrites a v1 source merely
because it is inspected.

Never commit real user config. Repository examples must contain no usernames,
absolute machine paths, account IDs, proxy ports, private endpoints, or
credentials.

## Launcher and prompt boundary

- Adapters build argument arrays; command strings and `Invoke-Expression` are
  prohibited.
- `.exe` executes directly. `.ps1` uses the current PowerShell host with fixed
  non-interactive flags.
- Native workers are created suspended with an explicit inherited-handle
  allowlist containing only stdin, stdout, and stderr, then assigned to the
  kill-on-close Job Object before their primary thread resumes.
- `.cmd` and `.bat` fail closed except the exact adapter-private MiniMax npm
  shim. That exception uses the system `cmd.exe`, disables delayed expansion,
  rejects shell metacharacters, quotes every fixed token, and transports the
  prompt only through a controlled temporary JSON message file.
- Claude Code receives the work order through standard input.
- Antigravity receives a controlled temporary work-order file, keeps its
  sandbox enabled, and registers only the canonical workspace plus that
  temporary directory.
- Prompt content must not appear in argv, arbitrary environment variables,
  diagnostics, or error messages.
- Temporary directories must use the AIW random namespace, be canonicalized
  before recursive cleanup, and be removed on success and failure.
- Cleanup failures are isolated from result construction. After a worker
  completes, AIW preserves its child exit code in the attempt, reports
  `cleanupFailed: true` with `wrapper_error` in the cleanup phase, and does
  not fall back.

Worker stdout and stderr are untrusted payloads. AIW decodes valid JSON stdout
and otherwise returns raw stdout text; an adapter's request for JSON output is
not a reason to reject a text response. It never parses stderr as output and
never publishes provider stderr in `diagnostics`; a non-empty stderr stream
receives a generic withheld message instead. Each stream is capped at 16 MiB.
Overflow terminates the process tree and returns `failureKind: output_limit`,
`error.code: OUTPUT_LIMIT`, `outputLimitExceeded: true`, and no captured
provider output.

Schema-2 `doctor` resolves approved executable paths and checks only the
existence of supported configured native profile directories. It does not open
profile files, execute hooks, inspect credentials, or contact a provider. A
selected unavailable profile fails before launch with `PROFILE_DIRECTORY_INVALID`.

## Capability, mode, and fallback boundary

`read` is a side-effect ceiling; it does not imply `workspace.read`. Repository
routes must explicitly request workspace access. Write always requires the
caller's explicit `-Mode write`.

Profiles may statically skip unavailable or capability-ineligible workers.
After a process starts:

- direct `-Worker`, `-NoFallback`, and every write call permit no cross-worker
  retry;
- permission, policy, configuration, capability, launcher, and wrapper failures
  never trigger fallback;
- timeout fallback is read-only, must be explicitly allowlisted, requires
  confirmed process-tree termination, and shares the original deadline;
- every later candidate is rechecked against the same canonical workspace,
  mode, and capabilities.

Never dispatch two writers into one checkout. Use separate Git worktrees and
inspect a partial write before any further model is allowed to act.

## Operational guidance

- Run `catalog`; validate an explicit config when one is selected; and use
  `status -OutputSchema 2` or `doctor -OutputSchema 2` before real-service
  smokes. Local probes are configuration evidence, not authentication proof.
- Prefer UTF-8 `PromptFile` for non-trivial work orders.
- Give an outer caller at least the AIW timeout plus cleanup headroom so AIW
  can return structured termination evidence.
- Never solve a permission failure with a bypass flag, global file grant,
  administrator elevation, or unrestricted provider tool policy.
- Treat a worker's success text as transport evidence only; independently
  inspect artifacts and run acceptance commands.

## Adapter admission

Security review for a new or changed adapter must cover the current upstream
official CLI documentation, exact launcher basenames/extensions, fixed
argument construction, prompt transport, native profile trust, capability
maximums, environment overlay allowlist, output decoding, timeout/cleanup, and
abuse-case tests. An upstream breaking change requires a new versioned adapter
ID when the existing contract cannot remain stable.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full conformance checklist.
