# Contributing

1. Keep the dispatcher secret-free and provider-neutral.
2. Preserve explicit read/write boundaries and structured JSON output.
3. Add a deterministic regression test for each transport, timeout, or
   permission bug.
4. Run the full PowerShell test suite before opening a pull request.

~~~powershell
.\tests\ai-workers.tests.ps1
.\ai-workers.ps1 status -Json
.\ai-workers.ps1 doctor -Json
~~~

Do not add permission bypasses, merged stdout/stderr parsing, new batch worker
launches, hard-coded usernames, absolute machine paths, account IDs, proxy
ports, or credentials. The existing MiniMax npm wrapper exception must remain
limited to validated static arguments and temporary message files. Describe the
route affected, safety boundary preserved, and verification evidence in every
pull request.
