[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'aiw'),
    [switch]$RemoveCodexSkill,
    [switch]$RemoveUserConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$defaultRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'aiw')).TrimEnd('\')
if ($rootFull -ne $defaultRoot) {
    throw 'Uninstall only supports the default per-user installation root.'
}

$appDirectory = Join-Path $rootFull 'app'
$markerPath = Join-Path $appDirectory '.aiw-install.json'
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw ('Refusing to remove an unmarked installation: {0}' -f $appDirectory)
}

$marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
if ($marker.product -ne 'aiw') {
    throw ('Refusing to remove an installation with an unexpected marker: {0}' -f $appDirectory)
}

if ($PSCmdlet.ShouldProcess($rootFull, 'remove AIW application files')) {
    Remove-Item -LiteralPath $rootFull -Recurse -Force
}

if ($RemoveCodexSkill) {
    $skillPath = Join-Path $env:USERPROFILE '.codex\skills\dispatch-ai-workers'
    if (Test-Path -LiteralPath $skillPath -PathType Container) {
        if ($PSCmdlet.ShouldProcess($skillPath, 'remove dispatch-ai-workers skill')) {
            Remove-Item -LiteralPath $skillPath -Recurse -Force
        }
    }
}

if ($RemoveUserConfig) {
    $configDirectory = Join-Path $env:USERPROFILE '.aiw'
    if (Test-Path -LiteralPath $configDirectory -PathType Container) {
        if ($PSCmdlet.ShouldProcess($configDirectory, 'remove AIW user configuration')) {
            Remove-Item -LiteralPath $configDirectory -Recurse -Force
        }
    }
}

Write-Output 'AIW application files were removed. User configuration is preserved unless -RemoveUserConfig was specified.'
