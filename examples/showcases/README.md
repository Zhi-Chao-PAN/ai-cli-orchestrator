# Showcases

Showcases are maintainer-specific policy examples. They are never installed,
discovered, or selected by default.

`maintainer-paid-plans.example.json` records one subscription strategy:
Google, MiniMax, Ark Coding (GLM first, Kimi second), Ark Agent, then a metered
DeepSeek profile. The order is not a recommendation. Model availability,
provider-native profile paths, quotas, and plan terms can change; review every
field before adapting the file.

Ark and DeepSeek credentials and endpoint settings belong in isolated native
Claude Code profile directories. The AIW showcase contains only references to
those directories; it contains no endpoint URL or credential.

Capability filtering still wins over this order. For example, the MiniMax
worker is skipped by the repository route because the reviewed MiniMax adapter
does not provide workspace access. Read-only fallback follows the profile's
allowlist; a started write attempt never falls through to another worker.
