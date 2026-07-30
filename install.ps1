[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'aiw'),
    [switch]$AddToPath,
    [switch]$InstallCodexSkill,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
    if (-not $childFull.StartsWith($parentFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing to operate outside installation root: {0}' -f $childFull)
    }
    return $childFull
}

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

function Write-AiwOwnershipMarker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ProductVersion
    )

    $marker = [ordered]@{
        product = 'aiw'
        schemaVersion = 1
        productVersion = $ProductVersion
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $content = (ConvertTo-Json -InputObject $marker -Depth 3) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries -contains $Path) {
        return
    }
    [Environment]::SetEnvironmentVariable('Path', (($entries + $Path) -join ';'), 'User')
}

function New-AiwSkillBackupPath {
    param([Parameter(Mandatory)][string]$SkillPath)

    $parent = Split-Path -Parent $SkillPath
    $name = Split-Path -Leaf $SkillPath
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $candidate = Join-Path $parent ('{0}.bak-{1}' -f $name, $timestamp)
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $parent ('{0}.bak-{1}-{2}' -f $name, $timestamp, $suffix)
        $suffix++
    }
    return $candidate
}

$sourceRoot = $PSScriptRoot
$requiredPaths = @(
    (Join-Path $sourceRoot 'ai-workers.ps1'),
    (Join-Path $sourceRoot 'bin\aiw.ps1'),
    (Join-Path $sourceRoot 'src\Aiw.Core.psm1'),
    (Join-Path $sourceRoot 'version.json'),
    (Join-Path $sourceRoot 'config.example.json'),
    (Join-Path $sourceRoot 'skill-src\dispatch-ai-workers\SKILL.md'),
    (Join-Path $sourceRoot 'skill-src\dispatch-ai-workers\agents\openai.yaml')
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw ('This installer must be run from a complete AI CLI Orchestrator release. Missing: {0}' -f $requiredPath)
    }
}

try {
    $versionDocument = [System.IO.File]::ReadAllText((Join-Path $sourceRoot 'version.json')) | ConvertFrom-Json
    $versionProperty = $versionDocument.PSObject.Properties['productVersion']
    if ($null -eq $versionProperty) {
        throw 'Missing productVersion.'
    }
    $productVersion = ([string]$versionProperty.Value).Trim()
    if ($productVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw 'Invalid productVersion.'
    }
} catch {
    throw 'AIW version metadata is missing or invalid.'
}

$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($installRootFull)) {
    throw 'Installation root is invalid.'
}
$appDirectory = Assert-ChildPath -Parent $installRootFull -Child (Join-Path $installRootFull 'app')
$binDirectory = Assert-ChildPath -Parent $installRootFull -Child (Join-Path $installRootFull 'bin')
$markerPath = Join-Path $appDirectory '.aiw-install.json'
$skillRoot = Join-Path $env:USERPROFILE '.codex\skills\dispatch-ai-workers'
$skillMarkerPath = Join-Path $skillRoot '.aiw-skill-install.json'
$skillPathExists = Test-Path -LiteralPath $skillRoot
$skillDirectoryExists = Test-Path -LiteralPath $skillRoot -PathType Container

$appPathExists = Test-Path -LiteralPath $appDirectory
if ($appPathExists -and -not (Test-Path -LiteralPath $appDirectory -PathType Container)) {
    throw ('Refusing to install over a non-directory application path: {0}' -f $appDirectory)
}
if ($appPathExists) {
    if (-not $Force) {
        throw ('Installation already exists at {0}. Re-run with -Force after reviewing it.' -f $appDirectory)
    }
    if (-not (Test-AiwOwnershipMarker -Path $markerPath)) {
        throw ('Refusing to replace an installation without a valid AIW marker: {0}' -f $appDirectory)
    }
} elseif (Test-Path -LiteralPath $installRootFull -PathType Container) {
    $rootItems = @(Get-ChildItem -LiteralPath $installRootFull -Force)
    if ($rootItems.Count -gt 0) {
        throw ('Refusing to install into a nonempty root without an AIW application marker: {0}' -f $installRootFull)
    }
}

if ($InstallCodexSkill -and $skillPathExists -and -not $skillDirectoryExists) {
    throw ('Refusing to replace a non-directory Codex skill path: {0}' -f $skillRoot)
}

$installed = $false
$skillBackupPath = $null
if ($PSCmdlet.ShouldProcess($installRootFull, 'install AI CLI Orchestrator')) {
    if ($appPathExists) {
        Remove-Item -LiteralPath $appDirectory -Recurse -Force
    }

    [void](New-Item -ItemType Directory -Path $appDirectory -Force)
    [void](New-Item -ItemType Directory -Path $binDirectory -Force)

    foreach ($name in @('ai-workers.ps1', 'version.json', 'config.example.json', 'README.md', 'README.zh-CN.md', 'WORK_ORDER_TEMPLATE.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md')) {
        $sourcePath = Join-Path $sourceRoot $name
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $appDirectory $name) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'bin\aiw.ps1') -Destination (Join-Path $binDirectory 'aiw.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'src') -Destination (Join-Path $appDirectory 'src') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'skill-src') -Destination (Join-Path $appDirectory 'skill-src') -Recurse -Force
    Write-AiwOwnershipMarker -Path $markerPath -ProductVersion $productVersion

    if ($InstallCodexSkill) {
        if ($skillDirectoryExists) {
            if (-not (Test-AiwOwnershipMarker -Path $skillMarkerPath)) {
                $skillBackupPath = New-AiwSkillBackupPath -SkillPath $skillRoot
                Copy-Item -LiteralPath $skillRoot -Destination $skillBackupPath -Recurse -Force
            }
            Remove-Item -LiteralPath $skillRoot -Recurse -Force
        }
        [void](New-Item -ItemType Directory -Path $skillRoot -Force)
        $skillSource = Join-Path $appDirectory 'skill-src\dispatch-ai-workers'
        Copy-Item -LiteralPath (Join-Path $skillSource 'SKILL.md') -Destination (Join-Path $skillRoot 'SKILL.md') -Force
        Copy-Item -LiteralPath (Join-Path $skillSource 'agents') -Destination $skillRoot -Recurse -Force
        Write-AiwOwnershipMarker -Path $skillMarkerPath -ProductVersion $productVersion
    }

    if ($AddToPath) {
        Add-UserPathEntry -Path $binDirectory
    }
    $installed = $true
}

if ($installed) {
    Write-Output ('Installed AIW to {0}' -f $installRootFull)
    if ($null -ne $skillBackupPath) {
        Write-Output ('Backed up the previous Codex skill to {0}' -f $skillBackupPath)
    }
    $launcherDisplayPath = (Join-Path $binDirectory 'aiw.ps1').Replace("'", "''")
    Write-Output ("Run: & '{0}' doctor -OutputSchema 2 -Json" -f $launcherDisplayPath)
} else {
    Write-Output 'Installation was not applied because WhatIf was specified.'
}
