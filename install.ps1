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

function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries -contains $Path) {
        return
    }
    [Environment]::SetEnvironmentVariable('Path', (($entries + $Path) -join ';'), 'User')
}

$sourceRoot = $PSScriptRoot
$requiredPaths = @(
    (Join-Path $sourceRoot 'ai-workers.ps1'),
    (Join-Path $sourceRoot 'bin\aiw.ps1'),
    (Join-Path $sourceRoot 'config.example.json'),
    (Join-Path $sourceRoot 'skill-src\dispatch-ai-workers\SKILL.md')
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw ('This installer must be run from a complete AI CLI Orchestrator release. Missing: {0}' -f $requiredPath)
    }
}

$installRootFull = [System.IO.Path]::GetFullPath($InstallRoot)
$appDirectory = Assert-ChildPath -Parent $installRootFull -Child (Join-Path $installRootFull 'app')
$binDirectory = Assert-ChildPath -Parent $installRootFull -Child (Join-Path $installRootFull 'bin')
$markerPath = Join-Path $appDirectory '.aiw-install.json'

if (Test-Path -LiteralPath $appDirectory) {
    if (-not $Force) {
        throw ('Installation already exists at {0}. Re-run with -Force after reviewing it.' -f $appDirectory)
    }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw ('Refusing to replace an unmarked directory: {0}' -f $appDirectory)
    }
    if ($PSCmdlet.ShouldProcess($appDirectory, 'replace existing AIW application files')) {
        Remove-Item -LiteralPath $appDirectory -Recurse -Force
    }
}

$installed = $false
if ($PSCmdlet.ShouldProcess($installRootFull, 'install AI CLI Orchestrator')) {
    [void](New-Item -ItemType Directory -Path $appDirectory -Force)
    [void](New-Item -ItemType Directory -Path $binDirectory -Force)

    foreach ($name in @('ai-workers.ps1', 'config.example.json', 'README.md', 'README.zh-CN.md', 'WORK_ORDER_TEMPLATE.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md')) {
        $sourcePath = Join-Path $sourceRoot $name
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $appDirectory $name) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'bin\aiw.ps1') -Destination (Join-Path $binDirectory 'aiw.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'skill-src') -Destination (Join-Path $appDirectory 'skill-src') -Recurse -Force

    $launcherPath = Join-Path $binDirectory 'aiw.ps1'
    $launcher = @'
param()
$entryPoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'app\ai-workers.ps1'
& $entryPoint @args
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($launcherPath, $launcher, (New-Object System.Text.UTF8Encoding($false)))
    $marker = [pscustomobject]@{
        product = 'aiw'
        schemaVersion = 1
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    ConvertTo-Json -InputObject $marker -Depth 3 | Set-Content -LiteralPath $markerPath -Encoding UTF8

    $configDirectory = Join-Path $env:USERPROFILE '.aiw'
    $configPath = Join-Path $configDirectory 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        [void](New-Item -ItemType Directory -Path $configDirectory -Force)
        Copy-Item -LiteralPath (Join-Path $appDirectory 'config.example.json') -Destination $configPath
    }

    if ($InstallCodexSkill) {
        $skillRoot = Join-Path $env:USERPROFILE '.codex\skills\dispatch-ai-workers'
        if (Test-Path -LiteralPath $skillRoot -PathType Container) {
            $backupPath = '{0}.bak-{1}' -f $skillRoot, [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
            Copy-Item -LiteralPath $skillRoot -Destination $backupPath -Recurse -Force
        }
        [void](New-Item -ItemType Directory -Path $skillRoot -Force)
        Copy-Item -LiteralPath (Join-Path $appDirectory 'skill-src\dispatch-ai-workers\SKILL.md') -Destination (Join-Path $skillRoot 'SKILL.md') -Force
        Copy-Item -LiteralPath (Join-Path $appDirectory 'skill-src\dispatch-ai-workers\agents') -Destination $skillRoot -Recurse -Force
    }

    if ($AddToPath) {
        Add-UserPathEntry -Path $binDirectory
    }
    $installed = $true
}

if ($installed) {
    Write-Output ('Installed AIW to {0}' -f $installRootFull)
    Write-Output ('Run: & {0} doctor -Json' -f (Join-Path $binDirectory 'aiw.ps1'))
} else {
    Write-Output 'Installation was not applied because WhatIf was specified.'
}
