# Contributing

AI CLI Orchestrator is provider-neutral orchestration with a deliberately
closed execution surface. Configuration expresses user policy; executable
integration code belongs in reviewed, versioned adapters.

## Development rules

1. Preserve the v0.2 compatibility facade and its schema v1 observable
   contract unless a separately approved migration says otherwise. The one
   documented v0.3 exception is that raw provider stderr must remain withheld
   behind a generic diagnostic.
2. Keep v2 selection provider-neutral. No maintainer model, account, plan, or
   provider order may become a config, installer, skill, discovery, or routing
   default.
3. Preserve explicit capability and read/write checks before process creation.
4. Keep configuration and repository artifacts secret-free.
5. Add a deterministic regression test for every transport, timeout,
   permission, selection, fallback, migration, or cleanup behavior.
6. Prefer stable machine-readable error codes over tests that assert only prose.

Do not add permission bypasses, merged stdout/stderr parsing, command strings,
`Invoke-Expression`, user-supplied argument templates, arbitrary environment
maps, repository-local config discovery, remote adapter loading, hard-coded
usernames or machine paths, account IDs, proxy ports, private endpoints, or
credentials.

## Adding or changing an adapter

An adapter is source code shipped with AIW, never JSON. Before implementation:

- link the current official CLI reference and, when claiming live upstream
  compatibility, record the tested CLI version and test date;
- define a versioned adapter ID and the smallest defensible maximum capability
  set;
- document whether the CLI can run non-interactively with explicit workspace
  and permission boundaries;
- identify every trusted native profile, hook, plugin, or executable extension;
- decide whether an upstream breaking change needs a new adapter ID.

The implementation must provide and test:

- a fixed descriptor and strict adapter-specific settings allowlist;
- reviewed executable basenames and extensions;
- argument arrays built only by adapter code;
- bounded stdin or AIW-owned temporary-file prompt transport with no prompt in
  argv;
- a fixed environment overlay allowlist with no arbitrary config values;
- preflight capability/mode validation before launch;
- separated stdout/stderr handling: valid JSON stdout decodes to structured
  output, raw stdout remains valid text, and provider stderr is withheld from
  public diagnostics rather than pattern-redacted and returned;
- central timeout, stream limit, process-tree termination, and guarded cleanup;
- stable failures for missing, unsafe, malformed, and incompatible launchers;
- abuse tests for secrets, arbitrary endpoint redirection, shell fields,
  capability escalation, prompt leakage, raw/JSON output, withheld stderr, and
  output overflow.

Ordinary `.cmd` and `.bat` launchers fail closed. The MiniMax npm shim is an
adapter-private reviewed exception; it cannot be enabled for another adapter
or widened to accept prompt text, arbitrary URLs, or arbitrary arguments.

The repository's deterministic adapter fixtures verify AIW's invocation
contract; they are not a standing claim that every later upstream CLI release
was tested live. A live compatibility claim must identify the exact upstream
version and verification date in the pull request or release evidence.

## Profiles, routes, and fallback

Profiles preserve user-declared worker order only after static eligibility
checks. Routes are explicit task classes and may not inspect prompt content.
Route requirements and caller-added requirements can narrow capabilities but
cannot expand an adapter.

Tests for profile/runtime changes must prove:

- capability filtering happens before provider order;
- `read` does not imply workspace access;
- a route cannot default to write;
- direct worker and `-NoFallback` calls start at most one worker;
- permission/policy/config/capability/launcher/wrapper failures never fall back;
- timeout fallback is read-only, opt-in, shares one deadline, and follows
  confirmed tree termination;
- no second worker starts after a write attempt begins;
- skips and attempts remain auditable in schema v2 output.

## Compatibility and migration

Schema v1 remains a supported input to the frozen v0.2 compatibility facade in
v0.3. Generic `run` and route/profile selection must require an explicit v2
migration rather than normalize a v1 file in memory. Schema-2 inventory may
report legacy provenance and migration guidance but must not manufacture v2
workers from the v1 file.
Any change behind a legacy alias requires golden tests for parameters, defaults,
JSON and non-JSON projection, child exit behavior, environment overrides, and
failure evidence. Raw provider stderr is the documented exception: test that it
is replaced by the generic withheld diagnostic instead of asserting legacy text.

Migration must be explicit and non-destructive: never modify the source, never
overwrite an existing destination, never add credentials, and validate the
generated v2 document. Upgrades preserve existing v1 and v2 user config.

## Documentation and examples

- `version.json` is the single product-version source. Runtime v2 envelopes
  and new ownership markers must agree with it; schema-v1 envelopes must not
  gain `productVersion`.
- `config.example.json` stays the neutral empty v2 shape.
- Generic examples may demonstrate reviewed adapters but must not impose a
  cross-provider default.
- Maintainer-specific plan combinations belong only under
  `examples/showcases/`, clearly labeled non-default and non-installed.
- README adapter tables must link upstream official documentation.
- Document the raw-text/JSON stdout convention, the fact that provider stderr
  is withheld from public diagnostics, and the `output_limit` / `OUTPUT_LIMIT`
  overflow contract.
- Describe doctor profile checks as non-invasive existence probes, never as
  profile, credential, hook, or live-service validation.
- Update English and Chinese docs together when public behavior changes.
- Installed skill instructions must select configured routes/profiles by
  capability rather than hardcoded provider names.

## Tests and verification

Run the public suite under both Windows PowerShell 5.1 and PowerShell 7:

~~~powershell
.\tests\ai-workers.tests.ps1
.\ai-workers.ps1 catalog -Json
.\ai-workers.ps1 config -Action validate -ConfigPath .\config.example.json -Json
~~~

Before submitting a pull request:

- run `git diff --check`;
- parse every JSON example;
- scan public files for keys, tokens, local usernames, absolute machine paths,
  personal account IDs, and private endpoints;
- verify fresh install, upgrade preservation, migration, and guarded uninstall
  in temporary user roots;
- run deterministic fixtures before optional bounded real-service smokes;
- prove raw-text and JSON stdout behavior, withheld provider stderr,
  `output_limit` / `OUTPUT_LIMIT`, and preflight failure for an unavailable
  configured profile when the change touches those paths;
- inspect the final diff independently rather than trusting worker self-report.

A release additionally requires a separate fresh Codex task to verify global
skill discovery, installed/source hashes, the complete regression suite, a
generic doctor inventory, and one structured bounded read call. Record
`COLD_START_PASS` or an evidence-backed `COLD_START_FAIL`.

Every pull request should state the route/adapter affected, the safety boundary
preserved, compatibility impact, exact acceptance commands, and observed
evidence.
