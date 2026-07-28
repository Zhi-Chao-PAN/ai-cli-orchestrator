# Objective

Perform a read-only correctness and security review of this Windows PowerShell
AI CLI orchestrator after a systemic reliability repair.

# Scope

Review only:

- ai-workers.ps1
- bin/aiw.ps1
- tests/ai-workers.tests.ps1
- README.md
- skill-src/dispatch-ai-workers/SKILL.md

# Focus

- Windows native argument quoting for exe, ps1, cmd, and bat workers.
- UTF-8 multiline PromptFile handling.
- Process timeout, child process tree termination, and output capture.
- Ark GLM to Kimi read-only fallback total timeout budget.
- Antigravity workspace registration and permission safety.
- JSON result consistency and secret leakage risk.

# Constraints

- Do not modify files.
- Do not use network access.
- Ignore style-only preferences.

# Response

List only actionable P0, P1, or P2 findings with file and line references. If
there are none, reply exactly: NO_ACTIONABLE_FINDINGS
