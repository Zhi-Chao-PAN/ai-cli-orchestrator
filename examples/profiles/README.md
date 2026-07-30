# Profile examples

`supported-clis.example.json` defines one independent worker, profile, and
route for each reviewed adapter. It intentionally has no default route, no
cross-provider priority, and no credentials.

Copy only the workers you actually use, set each model and optional path for
your local CLI, then create an ordered profile that reflects your own plans.
For MiniMax, change `region` to `global` when the account belongs to the
international service. Validate the result before dispatching:

~~~powershell
aiw config -Action validate -ConfigPath 'C:\path\to\config.json' -Json
~~~

Worker order is policy data. AIW first removes candidates that do not meet the
route's capabilities, then preserves the remaining profile order. Do not copy
the maintainer showcase unless that exact subscription layout fits you.
