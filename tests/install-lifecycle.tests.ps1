[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorRoot = Split-Path -Parent $PSScriptRoot
$installScriptPath = Join-Path $orchestratorRoot 'install.ps1'
$uninstallScriptPath = Join-Path $orchestratorRoot 'uninstall.ps1'
$sourceLauncherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
$versionMetadata = Get-Content -LiteralPath (Join-Path $orchestratorRoot 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ExpectedProductVersion = [string]$versionMetadata.productVersion
if ($script:ExpectedProductVersion -cne '0.3.0') {
    throw 'The release contract expects version 0.3.0.'
}
$script:Passed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ('{0}. Expected: <{1}> Actual: <{2}>' -f $Message, $Expected, $Actual)
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    & $Body
    $script:Passed++
    Write-Output ('PASS {0}' -f $Name)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Assert-ValidAiwMarker {
    param([Parameter(Mandatory)][string]$Path)

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message 'Expected marker file to exist'
    $marker = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
    Assert-Equal -Expected 'aiw' -Actual ([string]$marker.product) -Message 'Marker product changed'
    Assert-Equal -Expected 1 -Actual ([int]$marker.schemaVersion) -Message 'Marker schema changed'
    Assert-Equal -Expected $script:ExpectedProductVersion -Actual ([string]$marker.productVersion) -Message 'Marker product version changed'
}

function Get-CurrentPowerShellExecutable {
    $path = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $path
    }

    $candidate = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $candidate = Join-Path $PSHOME 'pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Could not resolve the current PowerShell executable.'
    }
    return $candidate
}

function Invoke-LauncherCatalog {
    param([Parameter(Mandatory)][string]$LauncherPath)

    $hostPath = Get-CurrentPowerShellExecutable
    $output = @(& $hostPath -NoLogo -NoProfile -NonInteractive -File $LauncherPath catalog -Json)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        exitCode = $exitCode
        text = ($output -join [Environment]::NewLine)
    }
}

function Invoke-LauncherDoctorV2 {
    param([Parameter(Mandatory)][string]$LauncherPath)

    $hostPath = Get-CurrentPowerShellExecutable
    $output = @(& $hostPath -NoLogo -NoProfile -NonInteractive -File $LauncherPath doctor -OutputSchema 2 -Json)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        exitCode = $exitCode
        text = ($output -join [Environment]::NewLine)
    }
}

function Invoke-InIsolatedUserRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $profileRoot = Join-Path $Root 'profile'
    $localAppDataRoot = Join-Path $Root 'local-app-data'
    [void](New-Item -ItemType Directory -Path $profileRoot -Force)
    [void](New-Item -ItemType Directory -Path $localAppDataRoot -Force)

    $hadUserProfile = Test-Path Env:USERPROFILE
    $hadLocalAppData = Test-Path Env:LOCALAPPDATA
    $originalUserProfile = $env:USERPROFILE
    $originalLocalAppData = $env:LOCALAPPDATA
    try {
        $env:USERPROFILE = $profileRoot
        $env:LOCALAPPDATA = $localAppDataRoot
        & $Body $profileRoot $localAppDataRoot
    } finally {
        if ($hadUserProfile) {
            $env:USERPROFILE = $originalUserProfile
        } else {
            Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
        }
        if ($hadLocalAppData) {
            $env:LOCALAPPDATA = $originalLocalAppData
        } else {
            Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
        }
    }
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase (
    'aiw-install-tests-{0}' -f [guid]::NewGuid().ToString('N')
)))
if (-not $tempRoot.StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create test files outside the system temporary directory.'
}
[void](New-Item -ItemType Directory -Path $tempRoot)

try {
    Invoke-Test -Name 'Fresh install creates no user configuration' -Body {
        $testRoot = Join-Path $tempRoot 'fresh-install'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            $installOutput = @(& $installScriptPath)
            $installRoot = Join-Path $localAppDataRoot 'aiw'
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installRoot 'app\ai-workers.ps1') -PathType Leaf) -Message 'Application was not installed'
            Assert-ValidAiwMarker -Path (Join-Path $installRoot 'app\.aiw-install.json')
            Assert-True -Condition ((@($installOutput) -join [Environment]::NewLine) -match 'doctor -OutputSchema 2 -Json') -Message 'Installer did not print the provider-neutral verification command'
            $doctorResult = Invoke-LauncherDoctorV2 -LauncherPath (Join-Path $installRoot 'bin\aiw.ps1')
            $doctor = $doctorResult.text | ConvertFrom-Json
            Assert-Equal -Expected 0 -Actual $doctorResult.exitCode -Message 'Printed v2 doctor command failed after installation'
            Assert-Equal -Expected 2 -Actual ([int]$doctor.schemaVersion) -Message 'Installed doctor schema changed'
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual ([string]$doctor.productVersion) -Message 'Installed doctor product version changed'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $profileRoot '.aiw'))) -Message 'Fresh install created a user configuration directory'
        }
    }

    Invoke-Test -Name 'Portable launcher works from source and installed layouts' -Body {
        $testRoot = Join-Path $tempRoot 'portable-launcher'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            $sourceResult = Invoke-LauncherCatalog -LauncherPath $sourceLauncherPath
            Assert-Equal -Expected 0 -Actual $sourceResult.exitCode -Message 'Source-layout launcher failed'
            Assert-True -Condition ($sourceResult.text -match '"command"\s*:\s*"catalog"') -Message 'Source launcher did not invoke the catalog command'
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual ([string](($sourceResult.text | ConvertFrom-Json).productVersion)) -Message 'Source catalog product version changed'

            & $installScriptPath | Out-Null
            $installedLauncher = Join-Path $localAppDataRoot 'aiw\bin\aiw.ps1'
            $installedResult = Invoke-LauncherCatalog -LauncherPath $installedLauncher
            Assert-Equal -Expected 0 -Actual $installedResult.exitCode -Message 'Installed-layout launcher failed'
            Assert-True -Condition ($installedResult.text -match '"command"\s*:\s*"catalog"') -Message 'Installed launcher did not invoke the catalog command'
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual ([string](($installedResult.text | ConvertFrom-Json).productVersion)) -Message 'Installed catalog product version changed'
        }
    }

    Invoke-Test -Name 'Force update accepts a valid v0.2 marker and preserves config bytes' -Body {
        $testRoot = Join-Path $tempRoot 'valid-force-update'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $installRoot = Join-Path $localAppDataRoot 'aiw'
            $appDirectory = Join-Path $installRoot 'app'
            Write-Utf8File -Path (Join-Path $appDirectory '.aiw-install.json') -Content '{"product":"aiw","schemaVersion":1,"installedAtUtc":"2026-07-27T00:00:00.0000000Z"}'
            $configDirectory = Join-Path $profileRoot '.aiw'
            [void](New-Item -ItemType Directory -Path $configDirectory -Force)
            $configPath = Join-Path $configDirectory 'config.json'
            $expectedBytes = [byte[]](0x7B, 0x0A, 0x20, 0x22, 0x6B, 0x22, 0x3A, 0x20, 0x31, 0x0A, 0x7D, 0x0A)
            [System.IO.File]::WriteAllBytes($configPath, $expectedBytes)

            & $installScriptPath -Force | Out-Null

            $actualBytes = [System.IO.File]::ReadAllBytes($configPath)
            Assert-Equal -Expected ($expectedBytes -join ',') -Actual ($actualBytes -join ',') -Message 'Force update changed user config bytes'
            Assert-ValidAiwMarker -Path (Join-Path $appDirectory '.aiw-install.json')
        }
    }

    Invoke-Test -Name 'Force update rejects unmarked and invalid installations without deletion' -Body {
        $testRoot = Join-Path $tempRoot 'invalid-force-update'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $appDirectory = Join-Path $localAppDataRoot 'aiw\app'
            $sentinelPath = Join-Path $appDirectory 'keep.txt'
            Write-Utf8File -Path $sentinelPath -Content 'do-not-delete'
            Remove-Item -LiteralPath (Join-Path $appDirectory '.aiw-install.json') -Force
            $unmarkedThrew = $false
            try {
                & $installScriptPath -Force | Out-Null
            } catch {
                $unmarkedThrew = $true
            }
            Assert-True -Condition $unmarkedThrew -Message 'Force update accepted an unmarked installation'
            Assert-True -Condition (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -Message 'Force update deleted an unmarked installation'

            Write-Utf8File -Path (Join-Path $appDirectory '.aiw-install.json') -Content '{"product":"other","schemaVersion":1}'
            $invalidThrew = $false
            try {
                & $installScriptPath -Force | Out-Null
            } catch {
                $invalidThrew = $true
            }
            Assert-True -Condition $invalidThrew -Message 'Force update accepted an invalid marker'
            Assert-True -Condition (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -Message 'Force update deleted an invalid installation'

            Write-Utf8File -Path (Join-Path $appDirectory '.aiw-install.json') -Content '{"product":"aiw","schemaVersion":2}'
            $unsupportedSchemaThrew = $false
            try {
                & $installScriptPath -Force | Out-Null
            } catch {
                $unsupportedSchemaThrew = $true
            }
            Assert-True -Condition $unsupportedSchemaThrew -Message 'Force update accepted an unsupported marker schema'
            Assert-True -Condition (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -Message 'Force update deleted an unsupported marker schema installation'
        }
    }

    Invoke-Test -Name 'Installer writes an ownership marker for its Codex skill' -Body {
        $testRoot = Join-Path $tempRoot 'skill-marker'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath -InstallCodexSkill | Out-Null
            $skillRoot = Join-Path $profileRoot '.codex\skills\dispatch-ai-workers'
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') -PathType Leaf) -Message 'Skill entry point was not installed'
            Assert-ValidAiwMarker -Path (Join-Path $skillRoot '.aiw-skill-install.json')
        }
    }

    Invoke-Test -Name 'Installer backs up a pre-existing unmarked Codex skill before replacement' -Body {
        $testRoot = Join-Path $tempRoot 'preserve-foreign-skill-on-install'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            $skillRoot = Join-Path $profileRoot '.codex\skills\dispatch-ai-workers'
            [void](New-Item -ItemType Directory -Path $skillRoot -Force)
            $skillEntry = Join-Path $skillRoot 'SKILL.md'
            Write-Utf8File -Path $skillEntry -Content 'user-owned skill'

            & $installScriptPath -InstallCodexSkill | Out-Null

            Assert-ValidAiwMarker -Path (Join-Path $skillRoot '.aiw-skill-install.json')
            $skillParent = Split-Path -Parent $skillRoot
            $backups = @(Get-ChildItem -LiteralPath $skillParent -Directory | Where-Object { $_.Name -like 'dispatch-ai-workers.bak-*' })
            Assert-Equal -Expected 1 -Actual $backups.Count -Message 'Installer did not create one backup for the unmarked skill'
            $backupEntry = Join-Path $backups[0].FullName 'SKILL.md'
            Assert-True -Condition (Test-Path -LiteralPath $backupEntry -PathType Leaf) -Message 'Installer backup did not preserve the old skill entry point'
            Assert-Equal -Expected 'user-owned skill' -Actual (Get-Content -LiteralPath $backupEntry -Raw) -Message 'Installer backup changed the old skill content'
        }
    }

    Invoke-Test -Name 'Uninstall preserves an unmarked Codex skill' -Body {
        $testRoot = Join-Path $tempRoot 'preserve-unmarked-skill'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $skillRoot = Join-Path $profileRoot '.codex\skills\dispatch-ai-workers'
            [void](New-Item -ItemType Directory -Path $skillRoot -Force)
            $skillEntry = Join-Path $skillRoot 'SKILL.md'
            Write-Utf8File -Path $skillEntry -Content 'user-owned skill'

            & $uninstallScriptPath -RemoveCodexSkill | Out-Null
            Assert-True -Condition (Test-Path -LiteralPath $skillEntry -PathType Leaf) -Message 'Uninstall deleted an unmarked skill'
        }
    }

    Invoke-Test -Name 'Uninstall rejects an invalid application marker without deletion' -Body {
        $testRoot = Join-Path $tempRoot 'guarded-uninstall'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $appDirectory = Join-Path $localAppDataRoot 'aiw\app'
            $sentinelPath = Join-Path $appDirectory 'keep.txt'
            Write-Utf8File -Path $sentinelPath -Content 'do-not-delete'
            Write-Utf8File -Path (Join-Path $appDirectory '.aiw-install.json') -Content '{"product":"other","schemaVersion":1}'

            $threw = $false
            try {
                & $uninstallScriptPath | Out-Null
            } catch {
                $threw = $true
            }
            Assert-True -Condition $threw -Message 'Uninstall accepted an invalid application marker'
            Assert-True -Condition (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -Message 'Uninstall deleted an invalid application root'
        }
    }

    Invoke-Test -Name 'Uninstall removes an AIW-owned Codex skill' -Body {
        $testRoot = Join-Path $tempRoot 'remove-owned-skill'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath -InstallCodexSkill | Out-Null
            $skillRoot = Join-Path $profileRoot '.codex\skills\dispatch-ai-workers'
            & $uninstallScriptPath -RemoveCodexSkill | Out-Null
            Assert-True -Condition (-not (Test-Path -LiteralPath $skillRoot)) -Message 'Uninstall did not remove its owned skill'
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $localAppDataRoot 'aiw'))) -Message 'Uninstall did not remove the application root'
        }
    }

    Invoke-Test -Name 'RemoveUserConfig removes only config and leaves other user files' -Body {
        $testRoot = Join-Path $tempRoot 'narrow-config-removal'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $configDirectory = Join-Path $profileRoot '.aiw'
            [void](New-Item -ItemType Directory -Path $configDirectory -Force)
            $configPath = Join-Path $configDirectory 'config.json'
            $notesPath = Join-Path $configDirectory 'notes.txt'
            Write-Utf8File -Path $configPath -Content '{"schemaVersion":2}'
            Write-Utf8File -Path $notesPath -Content 'preserve me'

            & $uninstallScriptPath -RemoveUserConfig | Out-Null
            Assert-True -Condition (-not (Test-Path -LiteralPath $configPath)) -Message 'Uninstall did not remove config.json'
            Assert-True -Condition (Test-Path -LiteralPath $notesPath -PathType Leaf) -Message 'Uninstall removed unrelated user files'
            Assert-True -Condition (Test-Path -LiteralPath $configDirectory -PathType Container) -Message 'Uninstall removed a nonempty config directory'
        }
    }

    Invoke-Test -Name 'RemoveUserConfig removes an empty config directory after config.json' -Body {
        $testRoot = Join-Path $tempRoot 'empty-config-removal'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $configDirectory = Join-Path $profileRoot '.aiw'
            [void](New-Item -ItemType Directory -Path $configDirectory -Force)
            Write-Utf8File -Path (Join-Path $configDirectory 'config.json') -Content '{"schemaVersion":2}'

            & $uninstallScriptPath -RemoveUserConfig | Out-Null
            Assert-True -Condition (-not (Test-Path -LiteralPath $configDirectory)) -Message 'Uninstall kept an empty config directory'
        }
    }

    Invoke-Test -Name 'WhatIf preserves application and user configuration' -Body {
        $testRoot = Join-Path $tempRoot 'whatif'
        Invoke-InIsolatedUserRoot -Root $testRoot -Body {
            param($profileRoot, $localAppDataRoot)

            & $installScriptPath | Out-Null
            $configDirectory = Join-Path $profileRoot '.aiw'
            [void](New-Item -ItemType Directory -Path $configDirectory -Force)
            $configPath = Join-Path $configDirectory 'config.json'
            Write-Utf8File -Path $configPath -Content '{"schemaVersion":2}'

            & $uninstallScriptPath -RemoveUserConfig -WhatIf | Out-Null
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $localAppDataRoot 'aiw\app\.aiw-install.json') -PathType Leaf) -Message 'WhatIf removed the application'
            Assert-True -Condition (Test-Path -LiteralPath $configPath -PathType Leaf) -Message 'WhatIf removed the user configuration'
        }
    }
} finally {
    if ($tempRoot.StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output ('All {0} installer lifecycle tests passed.' -f $script:Passed)
