param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entryPoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'ai-workers.ps1'
if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
    throw ('aiw entry point is missing: {0}' -f $entryPoint)
}

& $entryPoint @args
$entryPointSucceeded = $?
$entryPointExitCode = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $entryPointExitCode) {
    exit [int]$entryPointExitCode
}
if (-not $entryPointSucceeded) {
    exit 1
}
exit 0
