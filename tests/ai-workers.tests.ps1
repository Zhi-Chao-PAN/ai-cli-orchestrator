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

    Invoke-Test -Name 'PowerShell launcher returns zero after a successful worker' -Body {
        $fakeWorkerPath = Join-Path $tempRoot 'successful-worker.ps1'
        $configPath = Join-Path $tempRoot 'launcher-success-config.json'
        [System.IO.File]::WriteAllText(
            $fakeWorkerPath,
            '[Console]::Write(([char]123).ToString() + [char]34 + ''fixture'' + [char]34 + '':'' + ''true'' + [char]125)',
            (New-Object System.Text.UTF8Encoding($false))
        )
        $configObject = [pscustomobject]@{
            workers = [pscustomobject]@{
                ark = [pscustomobject]@{
                    model = 'fixture-model'
                    path = $fakeWorkerPath
                }
            }
        }
        $config = ConvertTo-Json -InputObject $configObject -Depth 5 -Compress
        [System.IO.File]::WriteAllText(
            $configPath,
            $config,
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $launcherOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            ark `
            -Prompt 'fixture prompt' `
            -ConfigPath $configPath `
            -Json
        $launcherExitCode = $LASTEXITCODE
        $launcherResult = $launcherOutput | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $launcherExitCode -Message 'Launcher changed a successful worker exit code'
        Assert-True -Condition $launcherResult.ok -Message 'Launcher changed a successful worker result'
        Assert-True -Condition $launcherResult.output.fixture -Message 'Launcher lost worker output'
    }

    Invoke-Test -Name 'Catalog lists reviewed adapters through the public launcher' -Body {
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $catalogOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            catalog `
            -Json
        $catalogExitCode = $LASTEXITCODE
        $catalog = $catalogOutput | ConvertFrom-Json
        $adapterIds = @($catalog.adapters | ForEach-Object { $_.id })

        Assert-Equal -Expected 0 -Actual $catalogExitCode -Message 'Catalog command returned a non-zero exit code'
        Assert-Equal -Expected 2 -Actual $catalog.schemaVersion -Message 'Catalog schema changed'
        Assert-True -Condition $catalog.ok -Message 'Catalog command failed'
        Assert-Equal -Expected 'catalog' -Actual $catalog.command -Message 'Catalog command name changed'
        Assert-Equal -Expected 0 -Actual $catalog.exitCode -Message 'Catalog payload exit code changed'
        Assert-Equal -Expected 3 -Actual $adapterIds.Count -Message 'Catalog adapter count changed'
        Assert-Equal -Expected 'claude-code/v1' -Actual $adapterIds[0] -Message 'Claude adapter ID changed'
        Assert-Equal -Expected 'antigravity/v1' -Actual $adapterIds[1] -Message 'Antigravity adapter ID changed'
        Assert-Equal -Expected 'minimax-cli/v1' -Actual $adapterIds[2] -Message 'MiniMax adapter ID changed'
    }

    Invoke-Test -Name 'Config validate accepts the neutral schema v2 shape' -Body {
        $configPath = Join-Path $tempRoot 'neutral-v2.json'
        $neutralConfig = [pscustomobject]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [pscustomobject]@{}
            profiles = [pscustomobject]@{}
            routes = [pscustomobject]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $neutralConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $validationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action validate `
            -ConfigPath $configPath `
            -Json
        $validationExitCode = $LASTEXITCODE
        $validation = $validationOutput | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $validationExitCode -Message 'Neutral config validation failed'
        Assert-Equal -Expected 2 -Actual $validation.schemaVersion -Message 'Config result schema changed'
        Assert-True -Condition $validation.ok -Message 'Neutral config was rejected'
        Assert-Equal -Expected 'config' -Actual $validation.command -Message 'Config command name changed'
        Assert-Equal -Expected 'validate' -Actual $validation.action -Message 'Config action changed'
        Assert-Equal -Expected 2 -Actual $validation.configSchemaVersion -Message 'Config schema was not reported'
        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Config payload exit code changed'
        Assert-Equal -Expected 0 -Actual @($validation.errors).Count -Message 'Neutral config returned validation errors'
    }

    Invoke-Test -Name 'Config validate rejects command fields without echoing values' -Body {
        $configPath = Join-Path $tempRoot 'forbidden-command-v2.json'
        $secretSentinel = 'DO_NOT_ECHO_CONFIG_SENTINEL'
        $forbiddenConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{}
            profiles = [ordered]@{}
            routes = [ordered]@{}
            command = $secretSentinel
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $forbiddenConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $validationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action validate `
            -ConfigPath $configPath `
            -Json
        $validationExitCode = $LASTEXITCODE
        $validationText = @($validationOutput) -join [Environment]::NewLine
        $validation = $validationText | ConvertFrom-Json

        Assert-Equal -Expected 2 -Actual $validationExitCode -Message 'Forbidden config returned the wrong exit code'
        Assert-True -Condition (-not $validation.ok) -Message 'Forbidden command field was accepted'
        Assert-Equal -Expected 'config_invalid' -Actual $validation.failureKind -Message 'Forbidden field failure kind changed'
        Assert-Equal -Expected 'FIELD_FORBIDDEN' -Actual $validation.errors[0].code -Message 'Forbidden field error code changed'
        Assert-Equal -Expected '$.command' -Actual $validation.errors[0].path -Message 'Forbidden field path changed'
        Assert-True -Condition (-not $validationText.Contains($secretSentinel)) -Message 'Rejected config value leaked into JSON output'
    }

    Invoke-Test -Name 'Config validate rejects executable fields at nested paths' -Body {
        $configPath = Join-Path $tempRoot 'nested-command-v2.json'
        $nestedConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                review = [ordered]@{
                    adapter = 'antigravity/v1'
                    settings = [ordered]@{
                        command = 'nested-command-value'
                    }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $nestedConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $validationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action validate `
            -ConfigPath $configPath `
            -Json
        $validationExitCode = $LASTEXITCODE
        $validation = (@($validationOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 2 -Actual $validationExitCode -Message 'Nested executable field returned the wrong exit code'
        Assert-Equal -Expected 'FIELD_FORBIDDEN' -Actual $validation.errors[0].code -Message 'Nested executable field error code changed'
        Assert-Equal -Expected '$.workers.review.settings.command' -Actual $validation.errors[0].path -Message 'Nested executable field path changed'
    }

    Invoke-Test -Name 'Config validate rejects secret-like fields without echoing names or values' -Body {
        $configPath = Join-Path $tempRoot 'secret-field-v2.json'
        $secretSentinel = 'CONFIG_SECRET_VALUE_SENTINEL'
        $secretConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                review = [ordered]@{
                    adapter = 'antigravity/v1'
                    settings = [ordered]@{
                        apiKey = $secretSentinel
                    }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $secretConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $validationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action validate `
            -ConfigPath $configPath `
            -Json
        $validationExitCode = $LASTEXITCODE
        $validationText = @($validationOutput) -join [Environment]::NewLine
        $validation = $validationText | ConvertFrom-Json

        Assert-Equal -Expected 2 -Actual $validationExitCode -Message 'Secret-like field returned the wrong exit code'
        Assert-Equal -Expected 'FIELD_SECRET_FORBIDDEN' -Actual $validation.errors[0].code -Message 'Secret-like field error code changed'
        Assert-Equal -Expected '$.workers.review.settings.<redacted>' -Actual $validation.errors[0].path -Message 'Secret-like field path was not redacted'
        Assert-True -Condition (-not $validationText.Contains('apiKey')) -Message 'Secret-like field name leaked into JSON output'
        Assert-True -Condition (-not $validationText.Contains($secretSentinel)) -Message 'Secret-like field value leaked into JSON output'
    }

    Write-Output ('All {0} tests passed.' -f $script:Passed)
} finally {
    $resolvedTempBase = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path
    $resolvedTestRoot = (Resolve-Path -LiteralPath $tempRoot).Path
    if ($resolvedTestRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
