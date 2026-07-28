# Security policy

## Report a vulnerability

Do not publish provider credentials, local configuration contents, or an
exploitable proof of concept in a public issue. Use the repository host's
private security-report channel or ask a maintainer for a private contact.

Include the affected command, aiw version, Windows and PowerShell version,
minimal non-secret reproduction steps, and the structured result envelope.

## Boundaries

- Never commit credentials, work orders with secrets, or local configuration.
- Keep workers in explicit read or write mode and use one worktree per writer.
- Do not weaken Google sandboxing or add global file permissions to work
  around a task failure.
- Treat worker output and diagnostics as untrusted text.
- Prefer a bounded failure over an unscoped retry.
