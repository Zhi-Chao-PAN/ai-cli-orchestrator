[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorRoot = Split-Path -Parent $PSScriptRoot
$sutPath = Join-Path $orchestratorRoot 'ai-workers.ps1'
. $sutPath

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'aiw-tests-{0}' -f [guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $tempRoot)

try {
    Invoke-Test -Name 'PromptFile preserves UTF-8 multiline content' -Body {
        $promptPath = Join-Path $tempRoot 'work-order.md'
        $expected = '# Objective' + [Environment]::NewLine +
            [string][char]0x7B2C + [string][char]0x4E8C +
            ' line with quotes and slash'
        [System.IO.File]::WriteAllText(
            $promptPath,
            $expected,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $actual = Resolve-PromptText -FilePath $promptPath
        Assert-Equal -Expected $expected -Actual $actual -Message 'Prompt content changed'
    }

    Invoke-Test -Name 'Prompt and PromptFile are mutually exclusive' -Body {
        $promptPath = Join-Path $tempRoot 'exclusive.md'
        [System.IO.File]::WriteAllText($promptPath, 'file prompt')
        $threw = $false
        try {
            [void](Resolve-PromptText -InlinePrompt 'inline' -FilePath $promptPath)
        } catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message 'Expected mutually exclusive prompt inputs to fail'
    }

    Invoke-Test -Name 'Native runner preserves complex arguments' -Body {
        $echoPath = Join-Path $tempRoot 'echo-value.ps1'
        [System.IO.File]::WriteAllLines(
            $echoPath,
            @(
                'param([string]$Value)',
                '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)',
                '[Console]::Write($Value)'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $payload = 'line one' + [Environment]::NewLine +
            [string][char]0x7B2C + [string][char]0x4E8C + ' ' +
            [char]34 + 'quoted' + [char]34 + ' slash' + [char]92
        $result = Invoke-NativeWorker `
            -FilePath $echoPath `
            -Arguments @('-Value', $payload) `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds 10

        Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'Echo worker failed'
        Assert-Equal -Expected $payload -Actual $result.Output -Message 'Native argument changed'
    }

    Invoke-Test -Name 'Batch child workers fail closed' -Body {
        $batchPath = Join-Path $tempRoot 'unsafe-worker.cmd'
        [System.IO.File]::WriteAllText($batchPath, '@echo off')
        $threw = $false
        try {
            [void](Invoke-NativeWorker `
                -FilePath $batchPath `
                -Arguments @('noop') `
                -Directory $tempRoot `
                -ProcessTimeoutSeconds 10)
        } catch {
            $threw = $_.Exception.Message -match 'Batch worker launch is unsupported'
        }
        Assert-True -Condition $threw -Message 'Batch worker did not fail closed'
    }

    Invoke-Test -Name 'Native runner enforces process timeout' -Body {
        $sleepPath = Join-Path $tempRoot 'sleep.ps1'
        [System.IO.File]::WriteAllText(
            $sleepPath,
            'param([string]$Ignored) Start-Sleep -Seconds 10'
        )

        $result = Invoke-NativeWorker `
            -FilePath $sleepPath `
            -Arguments @('noop') `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds 1

        Assert-Equal -Expected 124 -Actual $result.ExitCode -Message 'Timeout exit code changed'
        Assert-True -Condition $result.TimedOut -Message 'Timeout was not marked'
        Assert-True `
            -Condition $result.TerminationSucceeded `
            -Message 'Timed-out process tree was not terminated'
        Assert-True `
            -Condition ($result.DurationMs -lt 5000) `
            -Message 'Process watchdog returned too late'
    }

    Invoke-Test -Name 'Timeout terminates descendant processes' -Body {
        $markerPath = Join-Path $tempRoot 'descendant-survived.txt'
        $childPath = Join-Path $tempRoot 'delayed-marker.ps1'
        $parentPath = Join-Path $tempRoot 'spawn-child.ps1'
        [System.IO.File]::WriteAllLines(
            $childPath,
            @(
                'param([string]$MarkerPath)',
                'Start-Sleep -Seconds 3',
                '[System.IO.File]::WriteAllText($MarkerPath, ''survived'')'
            )
        )
        [System.IO.File]::WriteAllLines(
            $parentPath,
            @(
                'param([string]$ChildPath, [string]$MarkerPath)',
                '$powerShellPath = Join-Path $PSHOME ''powershell.exe''',
                'Start-Process -FilePath $powerShellPath -ArgumentList @(''-NoProfile'', ''-NonInteractive'', ''-File'', $ChildPath, ''-MarkerPath'', $MarkerPath) -WindowStyle Hidden',
                'Start-Sleep -Seconds 10'
            )
        )

        $result = Invoke-NativeWorker `
            -FilePath $parentPath `
            -Arguments @('-ChildPath', $childPath, '-MarkerPath', $markerPath) `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds 1
        Start-Sleep -Seconds 4

        Assert-True -Condition $result.TimedOut -Message 'Parent process did not time out'
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath $markerPath)) `
            -Message 'A descendant process survived the timeout'
    }

    Invoke-Test -Name 'Permission failure is classified' -Body {
        $result = [pscustomobject]@{
            ExitCode = 1
            Output = 'headless mode cannot prompt; read_file permission was auto-denied'
            TimedOut = $false
            DurationMs = 10
        }
        $kind = Get-WorkerFailureKind -Result $result
        Assert-Equal `
            -Expected 'permission_denied' `
            -Actual $kind `
            -Message 'Failure classification changed'
    }

    Invoke-Test -Name 'Google worker keeps the work order out of command-line text' -Body {
        $workOrder = New-EphemeralGoogleWorkOrder -Text 'review unique work order'
        try {
            Assert-True -Condition (Test-Path -LiteralPath $workOrder.path) -Message 'Google work-order file was not created'
            $arguments = @(New-GoogleArguments -WorkOrderPath $workOrder.path -Directory $tempRoot -WorkOrderDirectory $workOrder.directory)
            Assert-True -Condition (-not ($arguments -contains 'review unique work order')) -Message 'Google prompt text leaked into arguments'
            $addDirectoryIndexes = @()
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                if ($arguments[$index] -eq '--add-dir') {
                    $addDirectoryIndexes += $index
                }
            }
            Assert-Equal -Expected 2 -Actual $addDirectoryIndexes.Count -Message 'Google requires both workspace and work-order directories'
            Assert-Equal -Expected $tempRoot -Actual $arguments[$addDirectoryIndexes[0] + 1] -Message 'Google workspace path changed'
            Assert-Equal -Expected $workOrder.directory -Actual $arguments[$addDirectoryIndexes[1] + 1] -Message 'Google work-order directory is missing'
            Assert-True -Condition ($arguments -contains '--sandbox') -Message 'Google sandbox flag is missing'
        } finally {
            Remove-AiwTemporaryDirectory -Path $workOrder.directory
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath $workOrder.directory)) -Message 'Google work-order directory was not removed'
    }

    Invoke-Test -Name 'Prompt byte limit rejects oversized input' -Body {
        $promptPath = Join-Path $tempRoot 'oversized.md'
        [System.IO.File]::WriteAllText($promptPath, '12345', (New-Object System.Text.UTF8Encoding($false)))
        $threw = $false
        try {
            [void](Resolve-PromptText -FilePath $promptPath -MaximumBytes 4)
        } catch {
            $threw = $_.Exception.Message -match 'exceeds'
        }
        Assert-True -Condition $threw -Message 'Oversized prompt was accepted'
    }

    Invoke-Test -Name 'Native runner keeps stdout separate from stderr' -Body {
        $ioPath = Join-Path $tempRoot 'stdout-stderr.ps1'
        [System.IO.File]::WriteAllLines(
            $ioPath,
            @(
                '[Console]::Out.Write(''stdout-only'')',
                '[Console]::Error.Write(''warning: stderr only'')'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $result = Invoke-NativeWorker -FilePath $ioPath -Arguments @('unused') -Directory $tempRoot -ProcessTimeoutSeconds 10
        Assert-Equal -Expected 'stdout-only' -Actual $result.StandardOutput -Message 'Stdout changed'
        Assert-Equal -Expected 'warning: stderr only' -Actual $result.StandardError -Message 'Stderr changed'
        Assert-Equal -Expected 'stdout-only' -Actual (Convert-OutputValue -Text $result.StandardOutput) -Message 'Output conversion used the wrong stream'
    }

    Invoke-Test -Name 'Claude work order is transported on standard input' -Body {
        $arguments = @(New-ClaudeArguments -SelectedModel 'test-model' -PermissionMode 'plan' -Tools 'Read')
        Assert-True -Condition (-not ($arguments -contains 'sensitive work order')) -Message 'Claude work order leaked into arguments'
        Assert-True -Condition ($arguments -contains 'Read the complete work order from standard input. Follow it only within the declared tool and permission constraints.') -Message 'Claude stdin bootstrap is missing'
    }

    Invoke-Test -Name 'MiniMax messages preserve Unicode in an ephemeral JSON file' -Body {
        $expected = [string][char]0x7B2C + [string][char]0x4E8C
        $messages = ConvertTo-MiniMaxMessages -Text $expected
        $parsed = $messages | ConvertFrom-Json
        Assert-Equal -Expected 1 -Actual @($parsed).Count -Message 'MiniMax payload must be a messages array'
        Assert-Equal -Expected $expected -Actual $parsed[0].content -Message 'MiniMax JSON payload changed'
        $workOrder = New-EphemeralMiniMaxMessages -Text $expected
        try {
            Assert-True -Condition (Test-Path -LiteralPath $workOrder.path) -Message 'MiniMax message file was not created'
            $fileText = [System.IO.File]::ReadAllText($workOrder.path, (New-Object System.Text.UTF8Encoding($false)))
            $fileMessages = $fileText | ConvertFrom-Json
            Assert-Equal -Expected 1 -Actual @($fileMessages).Count -Message 'MiniMax message file must contain an array'
            Assert-Equal -Expected $expected -Actual $fileMessages[0].content -Message 'MiniMax message file changed'
        } finally {
            Remove-AiwTemporaryDirectory -Path $workOrder.directory
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath $workOrder.directory)) -Message 'MiniMax message directory was not removed'
    }

    Invoke-Test -Name 'Environment restore removes variables that were originally absent' -Body {
        Remove-Item Env:AIW_TEST_RESTORE -ErrorAction SilentlyContinue
        $env:AIW_TEST_RESTORE = 'temporary'
        Restore-EnvironmentVariable -Name 'AIW_TEST_RESTORE' -PreviousValue $null
        Assert-True -Condition ([string]::IsNullOrWhiteSpace($env:AIW_TEST_RESTORE)) -Message 'Absent environment variable was restored as an empty value'
    }

    Invoke-Test -Name 'Portable config overrides defaults without secrets' -Body {
        $configPath = Join-Path $tempRoot 'config.json'
        $configObject = [pscustomobject]@{
            workers = [pscustomobject]@{
                ark = [pscustomobject]@{
                    model = 'portable-ark'
                    path = 'missing-ark.exe'
                }
                google = [pscustomobject]@{
                    model = 'portable-google'
                }
            }
        }
        $config = ConvertTo-Json -InputObject $configObject -Depth 5 -Compress
        [System.IO.File]::WriteAllText($configPath, $config, (New-Object System.Text.UTF8Encoding($false)))
        $previousConfigPath = $env:AIW_CONFIG_PATH
        try {
            $env:AIW_CONFIG_PATH = $configPath
            Initialize-AiwConfiguration
            Assert-Equal -Expected 'portable-ark' -Actual $script:WorkerConfig.ark.model -Message 'Config model override failed'
            Assert-Equal -Expected 'portable-google' -Actual $script:WorkerConfig.google.model -Message 'Config model override failed'
            Assert-True -Condition ([string]::IsNullOrWhiteSpace($script:ResolvedWorkerPaths['ark'])) -Message 'Missing configured executable should not resolve'
        } finally {
            Restore-EnvironmentVariable -Name 'AIW_CONFIG_PATH' -PreviousValue $previousConfigPath
            Initialize-AiwConfiguration
        }
    }

    Invoke-Test -Name 'Public transport paths avoid provider prompt arguments' -Body {
        $source = Get-Content -Raw -LiteralPath $sutPath
        Assert-True -Condition ($source -notmatch '--message([^\w-]|$)') -Message 'MiniMax prompt argument transport returned'
        Assert-True -Condition ($source -match '--messages-file') -Message 'MiniMax stdin message transport is missing'
        Assert-True -Condition ($source -match 'New-EphemeralGoogleWorkOrder') -Message 'Google ephemeral work-order transport is missing'
    }

    Invoke-Test -Name 'Public files contain no machine-specific source path' -Body {
        $publicFiles = @(
            (Join-Path $orchestratorRoot 'README.md'),
            (Join-Path $orchestratorRoot 'README.zh-CN.md'),
            (Join-Path $orchestratorRoot 'config.example.json'),
            (Join-Path $orchestratorRoot 'skill-src\dispatch-ai-workers\SKILL.md')
        )
        $machinePath = 'E:' + [char]92 + '22304'
        $userPath = 'C:' + [char]92 + 'Users' + [char]92 + '22304'
        foreach ($publicFile in $publicFiles) {
            $content = Get-Content -Raw -LiteralPath $publicFile
            Assert-True -Condition (-not $content.Contains($machinePath)) -Message ('Machine-specific path leaked into {0}' -f $publicFile)
            Assert-True -Condition (-not $content.Contains($userPath)) -Message ('User-specific path leaked into {0}' -f $publicFile)
        }
    }

    Invoke-Test -Name 'Example configuration parses as JSON' -Body {
        $examplePath = Join-Path $orchestratorRoot 'config.example.json'
        $example = Get-Content -Raw -LiteralPath $examplePath | ConvertFrom-Json
        Assert-Equal -Expected 'glm-5.2' -Actual $example.workers.ark.model -Message 'Example Ark model changed'
        Assert-Equal -Expected 'gemini-3.6-flash-high' -Actual $example.workers.google.model -Message 'Example Google model changed'
    }

    Invoke-Test -Name 'MiniMax batch wrapper settings are strictly validated' -Body {
        $valid = [pscustomobject]@{
            model = 'MiniMax-M3'
            baseUrl = 'https://api.example.test'
            quotaBaseUrl = 'https://quota.example.test'
        }
        Assert-MiniMaxSettings -Settings $valid
        $invalid = [pscustomobject]@{
            model = 'MiniMax-M3&unsafe'
            baseUrl = 'https://api.example.test'
            quotaBaseUrl = 'https://quota.example.test'
        }
        $threw = $false
        try {
            Assert-MiniMaxSettings -Settings $invalid
        } catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message 'Unsafe MiniMax model was accepted'
    }

    Invoke-Test -Name 'PowerShell launcher forwards command arguments' -Body {
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $launcherOutput = & $hostPath -NoLogo -NoProfile -NonInteractive -File $launcherPath status -Json
        $launcherStatus = $launcherOutput | ConvertFrom-Json
        Assert-Equal -Expected 'status' -Actual $launcherStatus.command -Message 'Launcher did not forward command'
        Assert-True -Condition $launcherStatus.ok -Message 'Launcher did not preserve JSON mode'
    }

    Write-Output ('All {0} tests passed.' -f $script:Passed)
} finally {
    $resolvedTempBase = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path
    $resolvedTestRoot = (Resolve-Path -LiteralPath $tempRoot).Path
    if ($resolvedTestRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
