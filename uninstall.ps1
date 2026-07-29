[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'aiw'),
    [switch]$RemoveCodexSkill,
    [switch]$RemoveUserConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AiwOwnershipMarker {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $false
        }
        $marker = $raw | ConvertFrom-Json
    } catch {
        return $false
    }

    if ($null -eq $marker) {
        return $false
    }
    $productProperty = $marker.PSObject.Properties['product']
    $schemaProperty = $marker.PSObject.Properties['schemaVersion']
    if ($null -eq $productProperty -or $null -eq $schemaProperty) {
        return $false
    }
    if ([string]$productProperty.Value -cne 'aiw') {
        return $false
    }

    $schemaValue = $schemaProperty.Value
    $isIntegral = $schemaValue -is [byte] -or
        $schemaValue -is [int16] -or
        $schemaValue -is [int32] -or
        $schemaValue -is [int64]
    if (-not $isIntegral) {
        return $false
    }
    return ([int64]$schemaValue -eq 1)
}

$rootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($rootFull)) {
    throw 'Installation root is invalid.'
}
$driveRoot = [System.IO.Path]::GetPathRoot($rootFull).TrimEnd('\')
if ($rootFull -eq $driveRoot) {
    throw 'Refusing to use a drive root as an installation root.'
}

$appDirectory = Join-Path $rootFull 'app'
$markerPath = Join-Path $appDirectory '.aiw-install.json'
if (-not (Test-AiwOwnershipMarker -Path $markerPath)) {
    throw ('Refusing to remove an installation without a valid AIW marker: {0}' -f $appDirectory)
}

$applicationRemoved = $false
if ($PSCmdlet.ShouldProcess($rootFull, 'remove AIW application files')) {
    Remove-Item -LiteralPath $rootFull -Recurse -Force
    $applicationRemoved = $true
}

if ($RemoveCodexSkill) {
    $skillPath = Join-Path $env:USERPROFILE '.codex\skills\dispatch-ai-workers'
    $skillMarkerPath = Join-Path $skillPath '.aiw-skill-install.json'
    if (Test-Path -LiteralPath $skillPath -PathType Container) {
        if (Test-AiwOwnershipMarker -Path $skillMarkerPath) {
            if ($PSCmdlet.ShouldProcess($skillPath, 'remove AIW-owned dispatch-ai-workers skill')) {
                Remove-Item -LiteralPath $skillPath -Recurse -Force
            }
        } else {
            Write-Warning ('Preserving an unmarked or foreign Codex skill: {0}' -f $skillPath)
        }
    }
}

if ($RemoveUserConfig) {
    $configDirectory = Join-Path $env:USERPROFILE '.aiw'
    $configPath = Join-Path $configDirectory 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($configPath, 'remove AIW user configuration file')) {
            Remove-Item -LiteralPath $configPath -Force
        }
    }
    if (Test-Path -LiteralPath $configDirectory -PathType Container) {
        $remainingItems = @(Get-ChildItem -LiteralPath $configDirectory -Force)
        if ($remainingItems.Count -eq 0 -and $PSCmdlet.ShouldProcess($configDirectory, 'remove empty AIW user configuration directory')) {
            Remove-Item -LiteralPath $configDirectory -Force
        }
    }
}

if ($applicationRemoved) {
    Write-Output 'AIW application files were removed. User configuration is preserved unless -RemoveUserConfig was specified.'
} else {
    Write-Output 'AIW application files were not removed because WhatIf was specified.'
}
