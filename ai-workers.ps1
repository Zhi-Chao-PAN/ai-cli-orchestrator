[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'doctor', 'ark', 'agent', 'google', 'minimax', 'quota', 'catalog', 'config', 'run')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$Prompt,

    [string]$PromptFile,

    [ValidateSet('read', 'write')]
    [string]$Mode = 'read',

    [string]$Model,

    [string]$GoogleModel,

    [string]$AgentModel,

    [string]$ConfigPath,

    [string]$Action,

    [string]$Destination,

    [string]$Worker,

    [string]$Profile,

    [string]$Route,

    [string[]]$RequireCapability,

    [ValidateRange(1, 16777216)]
    [int]$MaxPromptBytes = 1048576,

    [string]$WorkingDirectory = (Get-Location).Path,

    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,

    [switch]$NoFallback,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AiwCoreModulePath = Join-Path $PSScriptRoot 'src\Aiw.Core.psm1'
Import-Module -Name $script:AiwCoreModulePath -Force -ErrorAction Stop

$script:AiwVersion = '0.2.0'
$script:WorkerConfig = $null
$script:ConfigPathResolved = $null
$script:ResolvedWorkerPaths = @{}

function Get-AiwProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-AiwConfigValue {
    param(
        [object]$Config,
        [Parameter(Mandatory)][string[]]$Path,
        [object]$DefaultValue = $null
    )

    $current = $Config
    foreach ($segment in $Path) {
        $current = Get-AiwProperty -Object $current -Name $segment
        if ($null -eq $current) {
            return $DefaultValue
        }
    }
    return $current
}

function Resolve-AiwPath {
    param(
        [AllowNull()][string]$Path,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [System.IO.Path]::IsPathRooted($expanded) -and
        -not [string]::IsNullOrWhiteSpace($BaseDirectory)) {
        $expanded = Join-Path $BaseDirectory $expanded
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Resolve-AiwConfigPath {
    $requestedPath = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath
    } elseif (-not [string]::IsNullOrWhiteSpace($env:AIW_CONFIG_PATH)) {
        $env:AIW_CONFIG_PATH
    } else {
        $candidate = Join-Path $env:USERPROFILE '.aiw\config.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate } else { $null }
    }

    if ($null -eq $requestedPath) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $requestedPath -PathType Leaf)) {
        throw ('Configuration file does not exist: {0}' -f $requestedPath)
    }
    return (Resolve-Path -LiteralPath $requestedPath).Path
}

function Get-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Resolve-WorkerExecutable {
    param(
        [Parameter(Mandatory)][ValidateSet('ark', 'agent', 'google', 'minimax')]
        [string]$Worker,
        [AllowNull()][string]$ConfiguredPath
    )

    $environmentVariable = 'AIW_{0}_PATH' -f $Worker.ToUpperInvariant()
    $requestedPath = [Environment]::GetEnvironmentVariable($environmentVariable)
    if ([string]::IsNullOrWhiteSpace($requestedPath)) {
        $requestedPath = $ConfiguredPath
    }

    if (-not [string]::IsNullOrWhiteSpace($requestedPath)) {
        if (-not (Test-Path -LiteralPath $requestedPath -PathType Leaf)) {
            return $null
        }
        $resolved = (Resolve-Path -LiteralPath $requestedPath).Path
    } else {
        $commandName = switch ($Worker) {
            'ark' { 'claude' }
            'agent' { 'claude' }
            'google' { 'agy' }
            'minimax' { 'mmx' }
        }
        $command = Get-Command $commandName -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            $resolved = $command.Source
        } else {
            $fallbacks = switch ($Worker) {
                'ark' { @((Join-Path $env:APPDATA 'npm\claude.ps1')) }
                'agent' { @((Join-Path $env:APPDATA 'npm\claude.ps1')) }
                'google' { @((Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe')) }
                'minimax' { @((Join-Path $env:APPDATA 'npm\mmx.ps1')) }
            }
            $resolved = Get-FirstExistingPath -Candidates $fallbacks
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        return $null
    }
    $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($Worker -eq 'minimax' -and $extension -eq '.ps1') {
        $batchCandidate = [System.IO.Path]::ChangeExtension($resolved, '.cmd')
        if (Test-Path -LiteralPath $batchCandidate -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $batchCandidate).Path
            $extension = '.cmd'
        }
    }
    if (($extension -in @('.cmd', '.bat')) -and $Worker -ne 'minimax') {
        throw (
            'Worker executable resolves to a batch file. Configure a .ps1 or .exe ' +
            'entry point with {0}; batch entry points are rejected for safety.' -f $environmentVariable
        )
    }
    return $resolved
}

function Initialize-AiwConfiguration {
    $script:ConfigPathResolved = Resolve-AiwConfigPath
    $config = $null
    $configDirectory = $null
    if ($null -ne $script:ConfigPathResolved) {
        try {
            $config = Get-Content -Raw -LiteralPath $script:ConfigPathResolved | ConvertFrom-Json
            $configDirectory = Split-Path -Parent $script:ConfigPathResolved
        } catch {
            throw ('Configuration is not valid JSON: {0}' -f $script:ConfigPathResolved)
        }
    }

    $defaultMiniMaxConfig = Get-FirstExistingPath -Candidates @(
        (Join-Path $env:USERPROFILE '.mmx\config.json'),
        (Join-Path $env:USERPROFILE '.minimax\config.json')
    )
    $script:WorkerConfig = [pscustomobject]@{
        ark = [pscustomobject]@{
            path = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'ark', 'path')) -BaseDirectory $configDirectory
            model = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'ark', 'model') -DefaultValue 'glm-5.2')
            configPath = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'ark', 'configPath') -DefaultValue (Join-Path $env:USERPROFILE '.claude\settings.json')) -BaseDirectory $configDirectory
        }
        agent = [pscustomobject]@{
            path = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'agent', 'path')) -BaseDirectory $configDirectory
            model = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'agent', 'model') -DefaultValue 'ark-code-latest')
            configDirectory = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'agent', 'configDirectory') -DefaultValue (Join-Path $env:USERPROFILE '.claude-agent-plan')) -BaseDirectory $configDirectory
        }
        google = [pscustomobject]@{
            path = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'google', 'path')) -BaseDirectory $configDirectory
            model = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'google', 'model') -DefaultValue 'gemini-3.6-flash-high')
            configDirectory = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'google', 'configDirectory') -DefaultValue (Join-Path $env:USERPROFILE '.gemini\antigravity-cli')) -BaseDirectory $configDirectory
        }
        minimax = [pscustomobject]@{
            path = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'minimax', 'path')) -BaseDirectory $configDirectory
            model = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'minimax', 'model') -DefaultValue 'MiniMax-M3')
            configPath = Resolve-AiwPath -Path (Get-AiwConfigValue -Config $config -Path @('workers', 'minimax', 'configPath') -DefaultValue $defaultMiniMaxConfig) -BaseDirectory $configDirectory
            baseUrl = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'minimax', 'baseUrl') -DefaultValue 'https://api.minimaxi.com')
            quotaBaseUrl = [string](Get-AiwConfigValue -Config $config -Path @('workers', 'minimax', 'quotaBaseUrl') -DefaultValue 'https://www.minimaxi.com')
        }
    }

    $script:ClaudeConfigPath = $script:WorkerConfig.ark.configPath
    $script:AgentPlanConfigRoot = $script:WorkerConfig.agent.configDirectory
    $script:AgentPlanConfigPath = Join-Path $script:AgentPlanConfigRoot 'settings.json'
    $script:AntigravityConfigRoot = $script:WorkerConfig.google.configDirectory
    $script:MiniMaxConfigPath = $script:WorkerConfig.minimax.configPath
    foreach ($worker in @('ark', 'agent', 'google', 'minimax')) {
        $configuredWorker = Get-AiwProperty -Object $script:WorkerConfig -Name $worker
        $script:ResolvedWorkerPaths[$worker] = Resolve-WorkerExecutable -Worker $worker -ConfiguredPath $configuredWorker.path
    }
    $script:ClaudePath = $script:ResolvedWorkerPaths['ark']
    $script:AntigravityPath = $script:ResolvedWorkerPaths['google']
    $script:MiniMaxPath = $script:ResolvedWorkerPaths['minimax']
}

function Get-WorkerPath {
    param([Parameter(Mandatory)][ValidateSet('ark', 'agent', 'google', 'minimax')][string]$Worker)

    $path = $script:ResolvedWorkerPaths[$Worker]
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw (
            'The {0} worker executable was not found. Install its CLI, put it on PATH, ' +
            'or set AIW_{1}_PATH / workers.{0}.path in config.json.' -f $Worker, $Worker.ToUpperInvariant()
        )
    }
    return $path
}

function Get-CurrentPowerShellExecutable {
    try {
        $processPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($processPath) -and
            (Test-Path -LiteralPath $processPath -PathType Leaf)) {
            return $processPath
        }
    } catch {
        # Fall back to a stable PowerShell installation path.
    }
    foreach ($candidate in @((Join-Path $PSHOME 'pwsh.exe'), (Join-Path $PSHOME 'powershell.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw 'Could not resolve a PowerShell executable for a .ps1 worker.'
}

function Restore-EnvironmentVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$PreviousValue
    )

    if ($null -eq $PreviousValue) {
        Remove-Item -LiteralPath ('Env:{0}' -f $Name) -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath ('Env:{0}' -f $Name) -Value $PreviousValue
    }
}

function Resolve-WorkerDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Working directory does not exist: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PromptText {
    param(
        [string]$InlinePrompt,
        [string]$FilePath,
        [int]$MaximumBytes = $MaxPromptBytes
    )

    $hasInlinePrompt = -not [string]::IsNullOrWhiteSpace($InlinePrompt)
    $hasPromptFile = -not [string]::IsNullOrWhiteSpace($FilePath)

    if ($hasInlinePrompt -and $hasPromptFile) {
        throw 'Use either -Prompt or -PromptFile, not both.'
    }

    if ($hasPromptFile) {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            throw ('Prompt file does not exist: {0}' -f $FilePath)
        }

        $resolvedPromptFile = (Resolve-Path -LiteralPath $FilePath).Path
        if ((Get-Item -LiteralPath $resolvedPromptFile).Length -gt $MaximumBytes) {
            throw ('Prompt file exceeds the {0}-byte limit: {1}' -f $MaximumBytes, $resolvedPromptFile)
        }
        $reader = New-Object System.IO.StreamReader(
            $resolvedPromptFile,
            (New-Object System.Text.UTF8Encoding($false, $true)),
            $true
        )
        try {
            $fileText = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($fileText)) {
            throw ('Prompt file is empty: {0}' -f $resolvedPromptFile)
        }

        return $fileText
    }

    if ($hasInlinePrompt) {
        $byteCount = (New-Object System.Text.UTF8Encoding($false)).GetByteCount($InlinePrompt)
        if ($byteCount -gt $MaximumBytes) {
            throw ('Inline prompt exceeds the {0}-byte limit.' -f $MaximumBytes)
        }
        return $InlinePrompt
    }

    return $null
}

function Convert-OutputValue {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    try {
        return ($Text | ConvertFrom-Json)
    } catch {
        return $Text
    }
}

function Get-SanitizedDiagnostics {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)\bsk-[A-Za-z0-9_-]{8,}\b', '[REDACTED]'
    $sanitized = $sanitized -replace '(?i)\b(API[_-]?KEY|AUTHORIZATION|AUTH[_-]?TOKEN|TOKEN)\s*([:=])\s*\S+', '$1$2[REDACTED]'
    return $sanitized.TrimEnd()
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-WorkerProcessStartInfo {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Directory,

        [bool]$RedirectStandardInput,

        [bool]$AllowBatchWorker
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $launchPath = $FilePath
    $launchArguments = $Arguments

    if ($extension -eq '.ps1') {
        $launchPath = Get-CurrentPowerShellExecutable
        $launchArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', $FilePath
        ) + $Arguments
    } elseif ($extension -eq '.cmd' -or $extension -eq '.bat') {
        if (-not $AllowBatchWorker) {
            throw (
                'Batch worker launch is unsupported because cmd.exe cannot safely ' +
                'preserve arbitrary prompt arguments. Configure a .ps1 or .exe entry point.'
            )
        }
        if ([string]::IsNullOrWhiteSpace($env:ComSpec) -or
            -not (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) {
            throw 'cmd.exe is unavailable for the explicitly approved MiniMax wrapper.'
        }
        $launchPath = $env:ComSpec
        $launchArguments = @('/d', '/s', '/c', $FilePath) + $Arguments
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launchPath
    $startInfo.Arguments = ($launchArguments | ForEach-Object {
        ConvertTo-NativeArgument -Value ([string]$_)
    }) -join ' '
    $startInfo.WorkingDirectory = $Directory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $RedirectStandardInput
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        $startInfo.StandardInputEncoding = $utf8
        $startInfo.StandardOutputEncoding = $utf8
        $startInfo.StandardErrorEncoding = $utf8
    } catch {
        # Older .NET builds may not expose these setters.
    }

    return $startInfo
}

function Stop-WorkerProcessTree {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    if ($Process.HasExited) {
        return $true
    }

    $terminated = $false
    $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskKillPath -PathType Leaf) {
        try {
            & $taskKillPath /PID $Process.Id /T /F *> $null
            $terminated = $Process.WaitForExit(10000)
        } catch {
            $terminated = $false
        }
    }

    if (-not $terminated -and -not $Process.HasExited) {
        try {
            $Process.Kill()
            $terminated = $Process.WaitForExit(5000)
        } catch {
            $terminated = $false
        }
    }

    return ($terminated -or $Process.HasExited)
}

function Get-TaskTextWithin {
    param(
        [Parameter(Mandatory)]
        [object]$Task,

        [ValidateRange(1, 30000)]
        [int]$WaitMilliseconds = 5000
    )

    try {
        if (-not $Task.Wait($WaitMilliseconds)) {
            return [pscustomobject]@{ completed = $false; text = '' }
        }
        return [pscustomobject]@{
            completed = $true
            text = [string]$Task.GetAwaiter().GetResult()
        }
    } catch {
        return [pscustomobject]@{
            completed = $true
            text = ('[stream read failed: {0}]' -f $_.Exception.Message)
        }
    }
}

function Invoke-NativeWorker {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateRange(1, 3600)]
        [int]$ProcessTimeoutSeconds,

        [AllowNull()]
        [string]$StandardInputText,

        [switch]$AllowBatchWorker
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Worker executable not found: $FilePath"
    }

    $hasStandardInput = $null -ne $StandardInputText
    $startInfo = New-WorkerProcessStartInfo -FilePath $FilePath -Arguments $Arguments -Directory $Directory -RedirectStandardInput $hasStandardInput -AllowBatchWorker $AllowBatchWorker
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $terminationSucceeded = $true

    try {
        if (-not $process.Start()) {
            throw ('Worker process failed to start: {0}' -f $FilePath)
        }

        if ($hasStandardInput) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
            $timedOut = $true
            $terminationSucceeded = Stop-WorkerProcessTree -Process $process
        } else {
            $process.WaitForExit()
        }

        $stdoutRead = Get-TaskTextWithin -Task $stdoutTask
        $stderrRead = Get-TaskTextWithin -Task $stderrTask
        $readTimedOut = -not ($stdoutRead.completed -and $stderrRead.completed)
        $exitCode = if ($timedOut) { 124 } elseif ($readTimedOut) { 125 } else { $process.ExitCode }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = $stdoutRead.text.TrimEnd()
            StandardOutput = $stdoutRead.text.TrimEnd()
            StandardError = $stderrRead.text.TrimEnd()
            TimedOut = $timedOut
            ReadTimedOut = $readTimedOut
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
            TerminationSucceeded = $terminationSucceeded
        }
    } finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

function Get-WorkerFailureKind {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    if ($Result.TimedOut) {
        return 'timeout'
    }
    if ((Get-AiwProperty -Object $Result -Name 'ReadTimedOut' -DefaultValue $false)) {
        return 'stream_drain_timeout'
    }
    if ($Result.ExitCode -eq 0) {
        return $null
    }

    $outputText = @(
        [string](Get-AiwProperty -Object $Result -Name 'StandardOutput' -DefaultValue (Get-AiwProperty -Object $Result -Name 'Output' -DefaultValue '')),
        [string](Get-AiwProperty -Object $Result -Name 'StandardError' -DefaultValue '')
    ) -join [Environment]::NewLine
    if (
        $outputText -match '(?i)headless mode cannot prompt' -or
        $outputText -match '(?i)auto-denied' -or
        $outputText -match '(?i)(permission|tool).{0,80}(denied|required)'
    ) {
        return 'permission_denied'
    }
    if ($outputText -match '(?i)(rate.?limit|quota|too many requests|429)') {
        return 'quota_or_rate_limit'
    }
    if ($outputText -match '(?i)(unauthorized|authentication|invalid.{0,20}(token|key)|\b401\b)') {
        return 'authentication'
    }

    return 'process_exit'
}

function New-WorkerAttempt {
    param(
        [string]$ModelName,

        [Parameter(Mandatory)]
        [object]$Result
    )

    return [pscustomobject]@{
        model = $ModelName
        exitCode = $Result.ExitCode
        timedOut = $Result.TimedOut
        readTimedOut = (Get-AiwProperty -Object $Result -Name 'ReadTimedOut' -DefaultValue $false)
        durationMs = $Result.DurationMs
        failureKind = Get-WorkerFailureKind -Result $Result
    }
}

function Get-RemainingTimeoutSeconds {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory)]
        [int]$TotalSeconds
    )

    $remaining = $TotalSeconds - [Math]::Ceiling($Stopwatch.Elapsed.TotalSeconds)
    return [Math]::Max(0, [int]$remaining)
}

function Write-WorkerResult {
    param(
        [Parameter(Mandatory)]
        [string]$Worker,

        [string]$SelectedModel,

        [Parameter(Mandatory)]
        [object[]]$Attempts,

        [Parameter(Mandatory)]
        [object]$Result
    )

    $failureKind = Get-WorkerFailureKind -Result $Result
    $diagnostics = Get-SanitizedDiagnostics -Text (
        [string](Get-AiwProperty -Object $Result -Name 'StandardError' -DefaultValue '')
    )
    if ($Json) {
        [pscustomobject]@{
            schemaVersion = 1
            ok = ($Result.ExitCode -eq 0)
            command = $Command
            worker = $Worker
            model = $SelectedModel
            mode = $Mode
            exitCode = $Result.ExitCode
            timedOut = $Result.TimedOut
            readTimedOut = (Get-AiwProperty -Object $Result -Name 'ReadTimedOut' -DefaultValue $false)
            terminationSucceeded = (Get-AiwProperty -Object $Result -Name 'TerminationSucceeded' -DefaultValue $false)
            durationMs = $Result.DurationMs
            failureKind = $failureKind
            attempts = $Attempts
            output = Convert-OutputValue -Text ([string]$Result.StandardOutput)
            diagnostics = $diagnostics
        } | ConvertTo-Json -Depth 20
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.StandardOutput)) {
            Write-Output $Result.StandardOutput
        }
        if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
            Write-Warning $diagnostics
        }
        if ($Result.ExitCode -ne 0 -and
            [string]::IsNullOrWhiteSpace([string]$Result.StandardOutput) -and
            [string]::IsNullOrWhiteSpace($diagnostics)) {
            Write-Error (
                'Worker failed with {0} (exit {1}).' -f $failureKind, $Result.ExitCode
            ) -ErrorAction Continue
        }
    }

    if ($Result.ExitCode -ne 0) {
        exit $Result.ExitCode
    }
}

function Get-SafeStatus {
    $claudeConfigured = $false
    $claudeModel = $null
    if (Test-Path -LiteralPath $script:ClaudeConfigPath) {
        try {
            $claudeSettings = Get-Content -Raw -LiteralPath $script:ClaudeConfigPath | ConvertFrom-Json
            $claudeConfigured = [bool]$claudeSettings.env.ANTHROPIC_BASE_URL -and
                [bool]$claudeSettings.env.ANTHROPIC_AUTH_TOKEN
            $claudeModel = $claudeSettings.env.ANTHROPIC_MODEL
        } catch {
            $claudeConfigured = $false
        }
    }

    $agentPlanConfigured = $false
    $agentPlanModel = $null
    if (Test-Path -LiteralPath $script:AgentPlanConfigPath) {
        try {
            $agentPlanSettings = Get-Content -Raw -LiteralPath $script:AgentPlanConfigPath | ConvertFrom-Json
            $agentPlanConfigured =
                [bool]$agentPlanSettings.env.ANTHROPIC_BASE_URL -and
                [bool]$agentPlanSettings.env.ANTHROPIC_AUTH_TOKEN
            $agentPlanModel = $agentPlanSettings.env.ANTHROPIC_MODEL
        } catch {
            $agentPlanConfigured = $false
        }
    }

    $miniMaxConfigured = $false
    $miniMaxRegion = $null
    if (Test-Path -LiteralPath $script:MiniMaxConfigPath) {
        try {
            $miniMaxSettings = Get-Content -Raw -LiteralPath $script:MiniMaxConfigPath | ConvertFrom-Json
            $miniMaxConfigured = [bool]$miniMaxSettings.api_key
            $miniMaxRegion = $miniMaxSettings.region
        } catch {
            $miniMaxConfigured = $false
        }
    }

    $status = @(
        [pscustomobject]@{
            Worker = 'ark'
            Installed = Test-Path -LiteralPath $script:ClaudePath
            AuthConfigured = $claudeConfigured
            DefaultModel = $script:WorkerConfig.ark.model
            ReadyHint = 'Run a bounded read task to verify service availability.'
        },
        [pscustomobject]@{
            Worker = 'agent'
            Installed = Test-Path -LiteralPath $script:ClaudePath
            AuthConfigured = $agentPlanConfigured
            DefaultModel = $script:WorkerConfig.agent.model
            ReadyHint = 'Uses a separate Claude Code profile and Agent Plan quota.'
        },
        [pscustomobject]@{
            Worker = 'google'
            Installed = Test-Path -LiteralPath $script:AntigravityPath
            AuthConfigured = Test-Path -LiteralPath $script:AntigravityConfigRoot
            DefaultModel = $script:WorkerConfig.google.model
            ReadyHint = 'Run a bounded read task to verify account and permission state.'
        },
        [pscustomobject]@{
            Worker = 'minimax'
            Installed = Test-Path -LiteralPath $script:MiniMaxPath
            AuthConfigured = $miniMaxConfigured
            DefaultModel = 'MiniMax-M3'
            ReadyHint = "Region: $miniMaxRegion"
        }
    )

    if ($Json) {
        $payload = [pscustomobject]@{
            schemaVersion = 1
            ok = $true
            command = 'status'
            configLoaded = ($null -ne $script:ConfigPathResolved)
            workers = $status
        }
        ConvertTo-Json -InputObject $payload -Depth 10
    } else {
        $status | Format-Table -AutoSize
    }
}

function Get-DoctorResult {
    $workers = @()
    $unresolved = 0
    foreach ($workerName in @('ark', 'agent', 'google', 'minimax')) {
        $resolved = -not [string]::IsNullOrWhiteSpace($script:ResolvedWorkerPaths[$workerName])
        if (-not $resolved) {
            $unresolved++
        }
        $workers += [pscustomobject]@{
            worker = $workerName
            executableResolved = $resolved
        }
    }
    $payload = [pscustomobject]@{
        schemaVersion = 1
        ok = ($unresolved -eq 0)
        command = 'doctor'
        configLoaded = ($null -ne $script:ConfigPathResolved)
        powershellExecutable = Get-CurrentPowerShellExecutable
        workers = $workers
    }
    if ($Json) {
        ConvertTo-Json -InputObject $payload -Depth 10
    } else {
        $workers | Format-Table -AutoSize
    }
}

function New-ClaudeArguments {
    param(
        [Parameter(Mandatory)][string]$SelectedModel,
        [Parameter(Mandatory)][string]$PermissionMode,
        [Parameter(Mandatory)][string]$Tools
    )

    return @(
        '-p', 'Read the complete work order from standard input. Follow it only within the declared tool and permission constraints.',
        '--model', $SelectedModel,
        '--permission-mode', $PermissionMode,
        '--tools', $Tools,
        '--no-session-persistence',
        '--output-format', 'json',
        '--max-turns', '20'
    )
}

function Invoke-Ark {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Directory
    )

    $selectedModel = if ([string]::IsNullOrWhiteSpace($Model)) { $script:WorkerConfig.ark.model } else { $Model }
    $permissionMode = if ($Mode -eq 'write') { 'acceptEdits' } else { 'plan' }
    $tools = if ($Mode -eq 'write') { 'Read,Glob,Grep,Edit,Write,Bash' } else { 'Read,Glob,Grep' }
    $previousApiTimeout = $env:API_TIMEOUT_MS
    $env:API_TIMEOUT_MS = [string]($TimeoutSeconds * 1000)
    $dispatchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $arguments = New-ClaudeArguments -SelectedModel $selectedModel -PermissionMode $permissionMode -Tools $tools
        $primary = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'ark') -Arguments $arguments -Directory $Directory -ProcessTimeoutSeconds $TimeoutSeconds -StandardInputText $Text
        $attempts = @(New-WorkerAttempt -ModelName $selectedModel -Result $primary)
        $remainingTimeout = Get-RemainingTimeoutSeconds -Stopwatch $dispatchStopwatch -TotalSeconds $TimeoutSeconds

        if ($primary.ExitCode -ne 0 -and $Mode -eq 'read' -and -not $NoFallback -and $selectedModel -eq 'glm-5.2' -and $remainingTimeout -gt 0) {
            $fallbackModel = 'kimi-k2.7-code'
            $fallbackArguments = New-ClaudeArguments -SelectedModel $fallbackModel -PermissionMode 'plan' -Tools 'Read,Glob,Grep'
            $fallback = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'ark') -Arguments $fallbackArguments -Directory $Directory -ProcessTimeoutSeconds $remainingTimeout -StandardInputText $Text
            $attempts += New-WorkerAttempt -ModelName $fallbackModel -Result $fallback
            Write-WorkerResult -Worker 'ark' -SelectedModel $fallbackModel -Attempts $attempts -Result $fallback
            return
        }

        Write-WorkerResult -Worker 'ark' -SelectedModel $selectedModel -Attempts $attempts -Result $primary
    } finally {
        $dispatchStopwatch.Stop()
        Restore-EnvironmentVariable -Name 'API_TIMEOUT_MS' -PreviousValue $previousApiTimeout
    }
}

function Invoke-AgentPlan {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $script:AgentPlanConfigPath)) {
        throw 'Agent Plan profile is missing. Set workers.agent.configDirectory in config.json before dispatching this worker.'
    }

    $selectedModel = if ([string]::IsNullOrWhiteSpace($AgentModel)) { $script:WorkerConfig.agent.model } else { $AgentModel }
    $permissionMode = if ($Mode -eq 'write') { 'acceptEdits' } else { 'plan' }
    $tools = if ($Mode -eq 'write') { 'Read,Glob,Grep,Edit,Write,Bash' } else { 'Read,Glob,Grep' }
    $previousConfigDirectory = $env:CLAUDE_CONFIG_DIR
    $previousApiTimeout = $env:API_TIMEOUT_MS
    $env:CLAUDE_CONFIG_DIR = $script:AgentPlanConfigRoot
    $env:API_TIMEOUT_MS = [string]($TimeoutSeconds * 1000)
    try {
        $arguments = New-ClaudeArguments -SelectedModel $selectedModel -PermissionMode $permissionMode -Tools $tools
        $result = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'agent') -Arguments $arguments -Directory $Directory -ProcessTimeoutSeconds $TimeoutSeconds -StandardInputText $Text
        $attempts = @(New-WorkerAttempt -ModelName $selectedModel -Result $result)
        Write-WorkerResult -Worker 'agent' -SelectedModel $selectedModel -Attempts $attempts -Result $result
    } finally {
        Restore-EnvironmentVariable -Name 'CLAUDE_CONFIG_DIR' -PreviousValue $previousConfigDirectory
        Restore-EnvironmentVariable -Name 'API_TIMEOUT_MS' -PreviousValue $previousApiTimeout
    }
}

function New-EphemeralGoogleWorkOrder {
    param([Parameter(Mandatory)][string]$Text)

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('aiw-google-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
    $path = Join-Path $directory 'work-order.md'
    try {
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Remove-AiwTemporaryDirectory -Path $directory
        throw
    }
    return [pscustomobject]@{ directory = $directory; path = $path }
}

function Remove-AiwTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $prefix = $temporaryRoot + '\'
    $leaf = Split-Path -Leaf $resolvedPath
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^aiw-(google|minimax)-[0-9a-f]{32}$') {
        throw ('Refusing to delete a non-AIW temporary directory: {0}' -f $resolvedPath)
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function New-GoogleArguments {
    param(
        [Parameter(Mandatory)][string]$WorkOrderPath,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$WorkOrderDirectory
    )

    $selectedModel = if ([string]::IsNullOrWhiteSpace($GoogleModel)) { $script:WorkerConfig.google.model } else { $GoogleModel }
    return @(
        '--print', ('Read and follow the complete work order in {0}.' -f $WorkOrderPath),
        '--model', $selectedModel,
        '--mode', $(if ($Mode -eq 'write') { 'accept-edits' } else { 'plan' }),
        '--print-timeout', ('{0}s' -f $TimeoutSeconds),
        '--add-dir', $Directory,
        '--add-dir', $WorkOrderDirectory,
        '--sandbox'
    )
}

function Invoke-Google {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Directory
    )

    $selectedModel = if ([string]::IsNullOrWhiteSpace($GoogleModel)) { $script:WorkerConfig.google.model } else { $GoogleModel }
    $workOrder = New-EphemeralGoogleWorkOrder -Text $Text
    try {
        $arguments = New-GoogleArguments -WorkOrderPath $workOrder.path -Directory $Directory -WorkOrderDirectory $workOrder.directory
        $result = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'google') -Arguments $arguments -Directory $Directory -ProcessTimeoutSeconds $TimeoutSeconds
        $attempts = @(New-WorkerAttempt -ModelName $selectedModel -Result $result)
        Write-WorkerResult -Worker 'google' -SelectedModel $selectedModel -Attempts $attempts -Result $result
    } finally {
        Remove-AiwTemporaryDirectory -Path $workOrder.directory
    }
}

function Assert-MiniMaxSettings {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [switch]$SkipModel
    )

    if (-not $SkipModel -and $Settings.model -notmatch '^[A-Za-z0-9._-]{1,128}$') {
        throw 'MiniMax model must contain only letters, numbers, dots, underscores, or hyphens.'
    }
    foreach ($urlValue in @($Settings.baseUrl, $Settings.quotaBaseUrl)) {
        if ([string]::IsNullOrWhiteSpace($urlValue)) {
            continue
        }
        $uri = $null
        if (-not [System.Uri]::TryCreate($urlValue, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or
            -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
            throw 'MiniMax endpoints must be absolute HTTPS URLs without embedded credentials.'
        }
    }
}

function ConvertTo-MiniMaxMessages {
    param([Parameter(Mandatory)][string]$Text)

    $messages = @(
        [pscustomobject]@{
            role = 'user'
            content = $Text
        }
    )
    return ConvertTo-Json -InputObject $messages -Depth 5 -Compress
}

function New-EphemeralMiniMaxMessages {
    param([Parameter(Mandatory)][string]$Text)

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('aiw-minimax-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
    $path = Join-Path $directory 'messages.json'
    try {
        [System.IO.File]::WriteAllText($path, (ConvertTo-MiniMaxMessages -Text $Text), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Remove-AiwTemporaryDirectory -Path $directory
        throw
    }
    return [pscustomobject]@{ directory = $directory; path = $path }
}

function Invoke-MiniMax {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Directory
    )

    if ($Mode -eq 'write') {
        throw 'MiniMax text mode is stateless and does not receive filesystem write access. Use ark or google for repository edits.'
    }

    $miniMax = $script:WorkerConfig.minimax
    Assert-MiniMaxSettings -Settings $miniMax
    $previousBaseUrl = $env:MINIMAX_BASE_URL
    $env:MINIMAX_BASE_URL = $miniMax.baseUrl
    $workOrder = $null
    try {
        $workOrder = New-EphemeralMiniMaxMessages -Text $Text
        $arguments = @(
            '--base-url', $miniMax.baseUrl,
            '--output', 'json',
            '--non-interactive',
            '--no-color',
            '--timeout', [string]$TimeoutSeconds,
            'text', 'chat',
            '--model', $miniMax.model,
            '--messages-file', $workOrder.path,
            '--max-tokens', '4096'
        )
        $result = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'minimax') -Arguments $arguments -Directory $Directory -ProcessTimeoutSeconds $TimeoutSeconds -AllowBatchWorker
        $attempts = @(New-WorkerAttempt -ModelName $miniMax.model -Result $result)
        Write-WorkerResult -Worker 'minimax' -SelectedModel $miniMax.model -Attempts $attempts -Result $result
    } finally {
        if ($null -ne $workOrder) {
            Remove-AiwTemporaryDirectory -Path $workOrder.directory
        }
        Restore-EnvironmentVariable -Name 'MINIMAX_BASE_URL' -PreviousValue $previousBaseUrl
    }
}

function Invoke-MiniMaxQuota {
    param([string]$Directory)

    $miniMax = $script:WorkerConfig.minimax
    Assert-MiniMaxSettings -Settings $miniMax -SkipModel
    $previousBaseUrl = $env:MINIMAX_BASE_URL
    $env:MINIMAX_BASE_URL = $miniMax.quotaBaseUrl
    try {
        $arguments = @(
            '--base-url', $miniMax.quotaBaseUrl,
            '--output', 'json',
            '--non-interactive',
            '--no-color',
            '--timeout', [string]$TimeoutSeconds,
            'quota', 'show'
        )
        $result = Invoke-NativeWorker -FilePath (Get-WorkerPath -Worker 'minimax') -Arguments $arguments -Directory $Directory -ProcessTimeoutSeconds $TimeoutSeconds -AllowBatchWorker
        $attempts = @(New-WorkerAttempt -ModelName 'Token Plan quota' -Result $result)
        Write-WorkerResult -Worker 'minimax-quota' -SelectedModel $null -Attempts $attempts -Result $result
    } finally {
        Restore-EnvironmentVariable -Name 'MINIMAX_BASE_URL' -PreviousValue $previousBaseUrl
    }
}

if ($MyInvocation.InvocationName -ne '.' -and $Command -in @('catalog', 'config', 'run')) {
    try {
        $coreRequest = if ($Command -eq 'catalog') {
            [pscustomobject]@{
                command = 'catalog'
            }
        } elseif ($Command -eq 'config') {
            if ($Action -ne 'validate') {
                throw 'The config command currently requires -Action validate.'
            }
            [pscustomobject]@{
                command = 'config.validate'
                configPath = $ConfigPath
            }
        } else {
            $resolvedDirectory = Resolve-WorkerDirectory -Path $WorkingDirectory
            $promptText = Resolve-PromptText -InlinePrompt $Prompt -FilePath $PromptFile
            if ([string]::IsNullOrWhiteSpace($promptText)) {
                throw 'The run command requires either -Prompt or -PromptFile.'
            }
            [pscustomobject]@{
                command = 'run.plan'
                configPath = $ConfigPath
                worker = $Worker
                profile = $Profile
                route = $Route
                mode = $Mode
                requiredCapabilities = @($RequireCapability)
                promptText = $promptText
                workingDirectory = $resolvedDirectory
                timeoutSeconds = $TimeoutSeconds
                noFallback = [bool]$NoFallback
            }
        }
        $coreResult = Invoke-AiwCore -Request $coreRequest
        if ($Command -eq 'run' -and $coreResult.ok) {
            $environmentPreviousValues = @{}
            try {
                foreach ($property in $coreResult.plan.environmentOverlay.PSObject.Properties) {
                    $environmentPreviousValues[$property.Name] = [Environment]::GetEnvironmentVariable($property.Name)
                    Set-Item -LiteralPath ('Env:{0}' -f $property.Name) -Value ([string]$property.Value)
                }
                $nativeResult = Invoke-NativeWorker `
                    -FilePath $coreResult.plan.filePath `
                    -Arguments @($coreResult.plan.arguments) `
                    -Directory $coreResult.plan.workingDirectory `
                    -ProcessTimeoutSeconds $TimeoutSeconds `
                    -StandardInputText $coreResult.plan.standardInputText `
                    -AllowBatchWorker:$coreResult.plan.allowBatchWorker
            } finally {
                foreach ($name in $environmentPreviousValues.Keys) {
                    Restore-EnvironmentVariable -Name $name -PreviousValue $environmentPreviousValues[$name]
                }
            }

            $failureKind = Get-WorkerFailureKind -Result $nativeResult
            $publicExitCode = if ($nativeResult.ExitCode -eq 0) {
                0
            } elseif ($nativeResult.TimedOut) {
                124
            } elseif ($nativeResult.ReadTimedOut) {
                125
            } else {
                1
            }
            $runResult = [pscustomobject]@{
                schemaVersion = 2
                ok = ($nativeResult.ExitCode -eq 0)
                command = 'run'
                request = $coreResult.request
                selection = $coreResult.selection
                exitCode = $publicExitCode
                timedOut = $nativeResult.TimedOut
                readTimedOut = $nativeResult.ReadTimedOut
                terminationSucceeded = $nativeResult.TerminationSucceeded
                durationMs = $nativeResult.DurationMs
                failureKind = $failureKind
                skipped = @()
                attempts = @(
                    [pscustomobject]@{
                        worker = $coreResult.selection.worker
                        adapter = $coreResult.selection.adapter
                        model = $coreResult.selection.model
                        childExitCode = $nativeResult.ExitCode
                        failureKind = $failureKind
                        timedOut = $nativeResult.TimedOut
                        readTimedOut = $nativeResult.ReadTimedOut
                        durationMs = $nativeResult.DurationMs
                    }
                )
                output = Convert-OutputValue -Text ([string]$nativeResult.StandardOutput)
                error = if ($nativeResult.ExitCode -eq 0) {
                    $null
                } else {
                    [pscustomobject]@{
                        code = $failureKind.ToUpperInvariant()
                        phase = 'execution'
                        message = 'Worker execution failed.'
                    }
                }
                diagnostics = Get-SanitizedDiagnostics -Text ([string]$nativeResult.StandardError)
                warnings = @()
            }
            if ($Json) {
                ConvertTo-Json -InputObject $runResult -Depth 20
            } else {
                if (-not [string]::IsNullOrWhiteSpace([string]$nativeResult.StandardOutput)) {
                    Write-Output $nativeResult.StandardOutput
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$runResult.diagnostics)) {
                    Write-Warning $runResult.diagnostics
                }
            }
            exit $publicExitCode
        }
        if ($Json) {
            ConvertTo-Json -InputObject $coreResult -Depth 20
        } elseif ($Command -eq 'config') {
            if ($coreResult.ok) {
                Write-Output ('Configuration is valid (schema {0}).' -f $coreResult.configSchemaVersion)
            } else {
                $coreResult.errors | Format-Table -AutoSize
            }
        } elseif ($Command -eq 'catalog') {
            $coreResult.adapters |
                Select-Object id, displayName, promptTransport, @{Name = 'capabilities'; Expression = { $_.capabilities -join ', ' }} |
                Format-Table -AutoSize
        }
        exit [int]$coreResult.exitCode
    } catch {
        if ($Json) {
            [pscustomobject]@{
                schemaVersion = 2
                ok = $false
                command = $Command
                action = if ($Command -eq 'config') { $Action } else { $null }
                exitCode = if ($Command -eq 'run') { 2 } else { 1 }
                failureKind = if ($Command -eq 'run') { 'invalid_request' } else { 'wrapper_error' }
                errors = @()
                error = [pscustomobject]@{
                    code = if ($Command -eq 'run') { 'INVALID_REQUEST' } else { 'WRAPPER_ERROR' }
                    message = 'Core request failed.'
                }
                diagnostics = Get-SanitizedDiagnostics -Text $_.Exception.Message
                warnings = @()
            } | ConvertTo-Json -Depth 20
        } else {
            Write-Error (Get-SanitizedDiagnostics -Text $_.Exception.Message) -ErrorAction Continue
        }
        exit $(if ($Command -eq 'run') { 2 } else { 1 })
    }
}

Initialize-AiwConfiguration

if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    if ($Command -eq 'status') {
        Get-SafeStatus
        exit 0
    }
    if ($Command -eq 'doctor') {
        Get-DoctorResult
        if (@($script:ResolvedWorkerPaths.Values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            exit 1
        }
        exit 0
    }

    $resolvedDirectory = Resolve-WorkerDirectory -Path $WorkingDirectory
    $promptText = if ($Command -eq 'quota') {
        $null
    } else {
        Resolve-PromptText -InlinePrompt $Prompt -FilePath $PromptFile
    }

    if ($Command -ne 'quota' -and [string]::IsNullOrWhiteSpace($promptText)) {
        throw (
            'The {0} command requires either -Prompt or -PromptFile.' -f $Command
        )
    }

    switch ($Command) {
        'ark' {
            Invoke-Ark -Text $promptText -Directory $resolvedDirectory
        }
        'agent' {
            Invoke-AgentPlan -Text $promptText -Directory $resolvedDirectory
        }
        'google' {
            Invoke-Google -Text $promptText -Directory $resolvedDirectory
        }
        'minimax' {
            Invoke-MiniMax -Text $promptText -Directory $resolvedDirectory
        }
        'quota' {
            Invoke-MiniMaxQuota -Directory $resolvedDirectory
        }
    }
} catch {
    if ($Json) {
        [pscustomobject]@{
            schemaVersion = 1
            ok = $false
            command = $Command
            worker = $Command
            model = $null
            mode = $Mode
            exitCode = 1
            timedOut = $false
            readTimedOut = $false
            durationMs = 0
            failureKind = 'wrapper_error'
            attempts = @()
            output = ''
            diagnostics = Get-SanitizedDiagnostics -Text $_.Exception.Message
        } | ConvertTo-Json -Depth 10
    } else {
        Write-Error (Get-SanitizedDiagnostics -Text $_.Exception.Message) -ErrorAction Continue
    }
    exit 1
}
