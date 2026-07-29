param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path -Parent $PSScriptRoot
$entryPoint = @(
    (Join-Path $releaseRoot 'ai-workers.ps1'),
    (Join-Path $releaseRoot 'app\ai-workers.ps1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($entryPoint)) {
    throw ('aiw entry point is missing below release root: {0}' -f $releaseRoot)
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
