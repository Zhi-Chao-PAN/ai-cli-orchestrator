param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entryPoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'ai-workers.ps1'
if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
    throw ('aiw entry point is missing: {0}' -f $entryPoint)
}

& $entryPoint @args
exit $LASTEXITCODE
