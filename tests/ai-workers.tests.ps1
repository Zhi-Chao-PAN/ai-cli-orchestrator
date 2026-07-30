[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorRoot = Split-Path -Parent $PSScriptRoot
$sutPath = Join-Path $orchestratorRoot 'ai-workers.ps1'
$versionMetadata = Get-Content -LiteralPath (Join-Path $orchestratorRoot 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ExpectedProductVersion = [string]$versionMetadata.productVersion
if ($script:ExpectedProductVersion -cne '0.3.0') {
    throw 'The release contract expects version 0.3.0.'
}
$script:SuccessProcessTimeoutSeconds = 30
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

function Invoke-PublicConfigValidation {
    param([Parameter(Mandatory)][string]$Path)

    $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
    $hostPath = Get-CurrentPowerShellExecutable
    $validationOutput = & $hostPath `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -File $launcherPath `
        config `
        -Action validate `
        -ConfigPath $Path `
        -Json
    $validationExitCode = $LASTEXITCODE
    $validationText = @($validationOutput) -join [Environment]::NewLine
    return [pscustomobject]@{
        exitCode = $validationExitCode
        text = $validationText
        result = $validationText | ConvertFrom-Json
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $Value -Depth 20),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function ConvertTo-LegacyComparableJson {
    param(
        [Parameter(Mandatory)][object]$Result,
        [switch]$IgnoreDiagnostics
    )

    $clone = ($Result | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $durationProperty = $clone.PSObject.Properties['durationMs']
    if ($null -ne $durationProperty) {
        $durationProperty.Value = 0
    }
    $attemptsProperty = $clone.PSObject.Properties['attempts']
    if ($null -ne $attemptsProperty) {
        foreach ($attempt in @($attemptsProperty.Value)) {
            $attemptDurationProperty = $attempt.PSObject.Properties['durationMs']
            if ($null -ne $attemptDurationProperty) {
                $attemptDurationProperty.Value = 0
            }
        }
    }
    if ($IgnoreDiagnostics) {
        $diagnosticsProperty = $clone.PSObject.Properties['diagnostics']
        if ($null -ne $diagnosticsProperty) {
            $diagnosticsProperty.Value = '<diagnostics-withheld-by-security-hardening>'
        }
    }
    return ($clone | ConvertTo-Json -Depth 30 -Compress)
}

function Invoke-LegacyGoldenCommand {
    param(
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$CommandName,
        [string]$ConfigPath,
        [string]$WorkingDirectory,
        [string]$PromptText = 'legacy golden prompt',
        [string]$PromptFile,
        [ValidateSet('read', 'write')][string]$Mode = 'read',
        [string]$Model,
        [string]$GoogleModel,
        [string]$AgentModel,
        [int]$MaxPromptBytes,
        [switch]$NoFallback,
        [switch]$UseDefaultMode,
        [switch]$UseDefaultTimeout,
        [switch]$Json,
        [switch]$ExplicitOutputSchema
    )

    $commandArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File', $ScriptPath,
        $CommandName
    )
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $commandArguments += @('-ConfigPath', $ConfigPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $commandArguments += @('-WorkingDirectory', $WorkingDirectory)
    }
    if (-not $UseDefaultTimeout) {
        $commandArguments += @('-TimeoutSeconds', '30')
    }
    if ($CommandName -ne 'status' -and $CommandName -ne 'doctor' -and $CommandName -ne 'quota') {
        if (-not $UseDefaultMode) {
            $commandArguments += @('-Mode', $Mode)
        }
        if ([string]::IsNullOrWhiteSpace($PromptFile)) {
            $commandArguments += @('-Prompt', $PromptText)
        } else {
            $commandArguments += @('-PromptFile', $PromptFile)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $commandArguments += @('-Model', $Model)
    }
    if (-not [string]::IsNullOrWhiteSpace($GoogleModel)) {
        $commandArguments += @('-GoogleModel', $GoogleModel)
    }
    if (-not [string]::IsNullOrWhiteSpace($AgentModel)) {
        $commandArguments += @('-AgentModel', $AgentModel)
    }
    if ($MaxPromptBytes -gt 0) {
        $commandArguments += @('-MaxPromptBytes', [string]$MaxPromptBytes)
    }
    if ($NoFallback) {
        $commandArguments += '-NoFallback'
    }
    if ($ExplicitOutputSchema) {
        $commandArguments += @('-OutputSchema', '1')
    }
    if ($Json) {
        $commandArguments += '-Json'
    }
    $output = & $HostPath @commandArguments
    return [pscustomobject]@{
        exitCode = $LASTEXITCODE
        text = @($output) -join [Environment]::NewLine
    }
}

function New-RoutingFixtureConfig {
    return [ordered]@{
        schemaVersion = 2
        defaultRoute = $null
        defaultProfile = $null
        workers = [ordered]@{
            fixture = [ordered]@{
                adapter = 'claude-code/v1'
                enabled = $true
                path = $null
                model = 'fixture-model'
                capabilities = @('text.reason', 'workspace.read')
                settings = [ordered]@{}
            }
        }
        profiles = [ordered]@{
            standard = [ordered]@{
                workers = @('fixture')
                fallback = [ordered]@{
                    maxAttempts = 1
                    on = @()
                }
            }
        }
        routes = [ordered]@{
            review = [ordered]@{
                profile = 'standard'
                requiredCapabilities = @('text.reason')
                defaultMode = 'read'
                allowedModes = @('read')
            }
        }
    }
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

    Invoke-Test -Name 'The public parameter binder preserves the legacy prompt-size range' -Body {
        $scriptInfo = Get-Command -Name $sutPath
        $range = @(
            $scriptInfo.Parameters['MaxPromptBytes'].Attributes |
                Where-Object {
                    $_ -is [System.Management.Automation.ValidateRangeAttribute]
                }
        )[0]
        Assert-Equal -Expected 1 -Actual $range.MinRange -Message 'Prompt-size minimum changed'
        Assert-Equal -Expected 16777216 -Actual $range.MaxRange -Message 'Legacy prompt-size ceiling changed'
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
            -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds

        Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'Echo worker failed'
        Assert-Equal -Expected $payload -Actual $result.Output -Message 'Native argument changed'
    }

    Invoke-Test -Name 'Native runner writes standard input as UTF-8 independently of the console code page' -Body {
        $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
        $echoPath = Join-Path $tempRoot 'echo-standard-input.js'
        [System.IO.File]::WriteAllText(
            $echoPath,
            'process.stdin.pipe(process.stdout);',
            (New-Object System.Text.UTF8Encoding($false))
        )
        $expected = 'UTF-8 ' + [string][char]0x7B2C + [string][char]0x4E8C
        $previousInputEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(1252)
            $result = Invoke-NativeWorker -FilePath $nodePath -Arguments @($echoPath) -Directory $tempRoot -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds -StandardInputText $expected
        } finally {
            [Console]::InputEncoding = $previousInputEncoding
        }

        Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'UTF-8 child failed'
        Assert-Equal -Expected $expected -Actual $result.StandardOutput -Message 'Standard input was not encoded as UTF-8'
    }

    Invoke-Test -Name 'Native runner inherits only its three reviewed standard-stream handles' -Body {
        if ($null -eq ('AiwTest.InheritableEventFixture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AiwTest
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct SecurityAttributes
    {
        internal int Length;
        internal IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        internal bool InheritHandle;
    }

    public sealed class InheritableEventFixture : IDisposable
    {
        private IntPtr handle;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateEvent(
            ref SecurityAttributes attributes,
            [MarshalAs(UnmanagedType.Bool)] bool manualReset,
            [MarshalAs(UnmanagedType.Bool)] bool initialState,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetHandleInformation(
            IntPtr target,
            out uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr target,
            uint milliseconds);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr target);

        public InheritableEventFixture()
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.InheritHandle = true;
            handle = CreateEvent(ref attributes, true, false, null);
            if (handle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public IntPtr HandleValue
        {
            get { return handle; }
        }

        public bool IsInheritable
        {
            get
            {
                uint flags;
                if (!GetHandleInformation(handle, out flags))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return (flags & 1) != 0;
            }
        }

        public bool IsSignaled
        {
            get { return WaitForSingleObject(handle, 0) == 0; }
        }

        public void Dispose()
        {
            if (handle == IntPtr.Zero) return;
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }
}
'@
        }

        $childPath = Join-Path $tempRoot 'probe-unlisted-inherited-handle.ps1'
        [System.IO.File]::WriteAllLines(
            $childPath,
            @(
                'param([string]$HandleValue)',
                'Add-Type -Namespace AiwChild -Name Native -MemberDefinition ''[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetEvent(System.IntPtr handle);''',
                '$handle = [IntPtr]([Int64]::Parse($HandleValue, [Globalization.CultureInfo]::InvariantCulture))',
                '[void][AiwChild.Native]::SetEvent($handle)',
                '[Console]::Write(''PROBE_RAN'')'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $fixture = New-Object AiwTest.InheritableEventFixture
        try {
            Assert-True -Condition $fixture.IsInheritable -Message 'Test fixture handle was not inheritable'
            $handleValue = $fixture.HandleValue.ToInt64().ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            $result = Invoke-NativeWorker `
                -FilePath $childPath `
                -Arguments @('-HandleValue', $handleValue) `
                -Directory $tempRoot `
                -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'Handle allowlist probe failed'
            Assert-Equal -Expected 'PROBE_RAN' -Actual $result.StandardOutput -Message 'Handle allowlist probe did not run'
            Assert-True -Condition (-not $fixture.IsSignaled) -Message 'A non-standard inheritable handle leaked into the worker'
        } finally {
            $fixture.Dispose()
        }
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
                -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds)
        } catch {
            $threw = $_.Exception.Message -match 'Batch worker launch is unsupported'
        }
        Assert-True -Condition $threw -Message 'Batch worker did not fail closed'
    }

    Invoke-Test -Name 'Reviewed MiniMax batch wrapper preserves safe quoted arguments' -Body {
        $batchRoot = Join-Path $tempRoot 'Program Files (x86)'
        [void](New-Item -ItemType Directory -Path $batchRoot)
        $capturePath = Join-Path $batchRoot 'capture-args.js'
        $batchPath = Join-Path $batchRoot 'mmx.cmd'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            $capturePath,
            'process.stdout.write(JSON.stringify(process.argv.slice(2)));',
            $utf8
        )
        [System.IO.File]::WriteAllLines(
            $batchPath,
            @(
                '@echo off',
                'node.exe "%~dp0capture-args.js" %*'
            ),
            $utf8
        )
        $expected = @(
            'plain',
            'two words',
            'C:\Program Files (x86)\MiniMax\message file.json',
            '',
            'paren(value)',
            'tail\'
        )

        $result = Invoke-NativeWorker `
            -FilePath $batchPath `
            -Arguments $expected `
            -Directory $batchRoot `
            -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds `
            -AllowBatchWorker

        Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'Reviewed batch wrapper failed'
        $parsedArguments = ConvertFrom-Json -InputObject $result.StandardOutput
        $actual = @($parsedArguments | ForEach-Object { $_ })
        Assert-Equal -Expected $expected.Count -Actual $actual.Count -Message 'Batch argument count changed'
        for ($index = 0; $index -lt $expected.Count; $index++) {
            Assert-Equal `
                -Expected $expected[$index] `
                -Actual $actual[$index] `
                -Message ('Batch argument {0} changed' -f $index)
        }
    }

    Invoke-Test -Name 'Reviewed MiniMax batch wrapper rejects unsafe cmd tokens and unrelated shims' -Body {
        $batchPath = Join-Path $tempRoot 'mmx.cmd'
        [System.IO.File]::WriteAllText($batchPath, '@echo off')
        $unsafeValues = @(
            'quote"break',
            'percent%PATH%',
            'bang!PATH!',
            'amp&whoami',
            'pipe|whoami',
            'input<file',
            'output>file',
            'caret^escape',
            "line`rbreak",
            "line`nbreak",
            ([string][char]0)
        )
        foreach ($unsafeValue in $unsafeValues) {
            $threw = $false
            try {
                [void](New-WorkerProcessStartInfo `
                    -FilePath $batchPath `
                    -Arguments @($unsafeValue) `
                    -Directory $tempRoot `
                    -RedirectStandardInput $false `
                    -AllowBatchWorker $true)
            } catch {
                $threw = $_.Exception.Message -match 'unsafe for cmd.exe'
            }
            Assert-True -Condition $threw -Message 'Unsafe cmd token was accepted'
        }

        $otherBatchPath = Join-Path $tempRoot 'other.cmd'
        [System.IO.File]::WriteAllText($otherBatchPath, '@echo off')
        $unrelatedThrew = $false
        try {
            [void](New-WorkerProcessStartInfo `
                -FilePath $otherBatchPath `
                -Arguments @('safe') `
                -Directory $tempRoot `
                -RedirectStandardInput $false `
                -AllowBatchWorker $true)
        } catch {
            $unrelatedThrew = $_.Exception.Message -match 'Only the reviewed MiniMax'
        }
        Assert-True -Condition $unrelatedThrew -Message 'An unrelated batch shim used the MiniMax exception'
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

    Invoke-Test -Name 'Native runner bounds an unread large standard input by the worker deadline' -Body {
        $sleepPath = Join-Path $tempRoot 'unread-standard-input.ps1'
        [System.IO.File]::WriteAllText(
            $sleepPath,
            'Start-Sleep -Seconds 30',
            (New-Object System.Text.UTF8Encoding($false))
        )

        $result = Invoke-NativeWorker `
            -FilePath $sleepPath `
            -Arguments @('unused') `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds 2 `
            -StandardInputText ('x' * 1048576)

        Assert-Equal -Expected 124 -Actual $result.ExitCode -Message 'Unread input timeout exit code changed'
        Assert-True -Condition $result.TimedOut -Message 'Unread input was not bounded by the deadline'
        Assert-True -Condition $result.TreeTerminationConfirmed -Message 'Unread input worker tree was not terminated'
        Assert-True -Condition ($result.DurationMs -lt 7000) -Message 'Unread input timeout returned too late'
    }

    Invoke-Test -Name 'Native runner fails closed when standard input cannot be delivered' -Body {
        $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
        $closeInputPath = Join-Path $tempRoot 'close-standard-input.js'
        [System.IO.File]::WriteAllText(
            $closeInputPath,
            "require('fs').closeSync(0); setTimeout(() => {}, 3000);",
            (New-Object System.Text.UTF8Encoding($false))
        )

        $result = Invoke-NativeWorker `
            -FilePath $nodePath `
            -Arguments @($closeInputPath) `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds `
            -StandardInputText ('x' * 1048576)

        Assert-Equal -Expected 125 -Actual $result.ExitCode -Message 'Undeliverable input exit code changed'
        Assert-True -Condition $result.InputWriteFailed -Message 'Undeliverable input was reported as success'
        Assert-Equal -Expected 'wrapper_error' -Actual (Get-WorkerFailureKind -Result $result) -Message 'Undeliverable input failure kind changed'
    }

    Invoke-Test -Name 'Timeout terminates descendant processes' -Body {
        for ($iteration = 1; $iteration -le 2; $iteration++) {
            $markerPath = Join-Path $tempRoot ('descendant-survived-{0}.txt' -f $iteration)
            $readyPath = Join-Path $tempRoot ('descendant-ready-{0}.txt' -f $iteration)
            $childPath = Join-Path $tempRoot ('delayed-marker-{0}.ps1' -f $iteration)
            $parentPath = Join-Path $tempRoot ('spawn-child-{0}.ps1' -f $iteration)
            [System.IO.File]::WriteAllLines(
                $childPath,
                @(
                    'param([string]$MarkerPath)',
                    'Start-Sleep -Seconds 20',
                    '[System.IO.File]::WriteAllText($MarkerPath, ''survived'')'
                )
            )
            [System.IO.File]::WriteAllLines(
                $parentPath,
                @(
                    'param([string]$ChildPath, [string]$MarkerPath, [string]$ReadyPath)',
                    '$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName',
                    '$childProcess = Start-Process -FilePath $powerShellPath -ArgumentList @(''-NoProfile'', ''-NonInteractive'', ''-File'', $ChildPath, ''-MarkerPath'', $MarkerPath) -WindowStyle Hidden -PassThru',
                    'Start-Sleep -Milliseconds 200',
                    '$childProcess.Refresh()',
                    'if ($childProcess.HasExited) { throw ''Child exited before containment was exercised.'' }',
                    '[System.IO.File]::WriteAllText($ReadyPath, [string]$childProcess.Id)',
                    'Start-Sleep -Seconds 30'
                )
            )

            $result = Invoke-NativeWorker `
                -FilePath $parentPath `
                -Arguments @('-ChildPath', $childPath, '-MarkerPath', $markerPath, '-ReadyPath', $readyPath) `
                -Directory $tempRoot `
                -ProcessTimeoutSeconds 10
            Assert-True -Condition (Test-Path -LiteralPath $readyPath) -Message 'Descendant did not become ready before the worker deadline'
            $childId = [int](Get-Content -LiteralPath $readyPath -Raw)
            Start-Sleep -Seconds 3

            Assert-True -Condition $result.TimedOut -Message 'Parent process did not time out'
            Assert-True -Condition $result.ContainmentApplied -Message 'Worker was not added to a containment job'
            Assert-True -Condition $result.TreeTerminationConfirmed -Message 'Worker job termination was not confirmed'
            Assert-True `
                -Condition ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) `
                -Message 'A descendant process remained after the timeout'
            Assert-True `
                -Condition (-not (Test-Path -LiteralPath $markerPath)) `
                -Message 'A descendant process wrote its delayed marker after the timeout'
        }
    }

    Invoke-Test -Name 'A successful worker cannot leave a descendant process behind' -Body {
        $markerPath = Join-Path $tempRoot 'successful-root-descendant.marker'
        $readyPath = Join-Path $tempRoot 'successful-root-descendant.ready'
        $childPath = Join-Path $tempRoot 'successful-root-child.ps1'
        $parentPath = Join-Path $tempRoot 'successful-root-parent.ps1'
        [System.IO.File]::WriteAllLines(
            $childPath,
            @(
                'param([string]$MarkerPath)',
                'Start-Sleep -Seconds 4',
                '[System.IO.File]::WriteAllText($MarkerPath, ''survived'')'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllLines(
            $parentPath,
            @(
                'param([string]$ChildPath, [string]$MarkerPath, [string]$ReadyPath)',
                '$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName',
                '$childProcess = Start-Process -FilePath $powerShellPath -ArgumentList @(''-NoProfile'', ''-NonInteractive'', ''-File'', $ChildPath, ''-MarkerPath'', $MarkerPath) -WindowStyle Hidden -PassThru',
                'Start-Sleep -Milliseconds 200',
                '$childProcess.Refresh()',
                'if ($childProcess.HasExited) { throw ''Child exited before containment was exercised.'' }',
                '[System.IO.File]::WriteAllText($ReadyPath, [string]$childProcess.Id)',
                '[Console]::Write(''ROOT_EXITED'')'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $result = Invoke-NativeWorker `
            -FilePath $parentPath `
            -Arguments @('-ChildPath', $childPath, '-MarkerPath', $markerPath, '-ReadyPath', $readyPath) `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds
        Assert-True -Condition (Test-Path -LiteralPath $readyPath) -Message 'Successful-root descendant did not become ready'
        $childId = [int](Get-Content -LiteralPath $readyPath -Raw)
        Start-Sleep -Seconds 5

        Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'Successful root changed exit code'
        Assert-Equal -Expected 'ROOT_EXITED' -Actual $result.StandardOutput -Message 'Successful root output changed'
        Assert-True -Condition $result.TreeTerminationConfirmed -Message 'Successful root did not terminate its Job Object descendants'
        Assert-True -Condition ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) -Message 'A descendant outlived a successful root worker'
        Assert-True -Condition (-not (Test-Path -LiteralPath $markerPath)) -Message 'A descendant wrote after a successful root worker returned'
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
        $result = Invoke-NativeWorker -FilePath $ioPath -Arguments @('unused') -Directory $tempRoot -ProcessTimeoutSeconds $script:SuccessProcessTimeoutSeconds
        Assert-Equal -Expected 'stdout-only' -Actual $result.StandardOutput -Message 'Stdout changed'
        Assert-Equal -Expected 'warning: stderr only' -Actual $result.StandardError -Message 'Stderr changed'
        Assert-Equal -Expected 'stdout-only' -Actual (Convert-OutputValue -Text $result.StandardOutput) -Message 'Output conversion used the wrong stream'
    }

    Invoke-Test -Name 'Native runner terminates a worker that exceeds its per-stream output limit' -Body {
        $floodPath = Join-Path $tempRoot 'stdout-flood.ps1'
        [System.IO.File]::WriteAllLines(
            $floodPath,
            @(
                '$stream = [Console]::OpenStandardOutput()',
                '$buffer = New-Object byte[] 8192',
                'for ($index = 0; $index -lt 2049; $index++) { $stream.Write($buffer, 0, $buffer.Length) }',
                'Start-Sleep -Seconds 10'
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $result = Invoke-NativeWorker `
            -FilePath $floodPath `
            -Arguments @('unused') `
            -Directory $tempRoot `
            -ProcessTimeoutSeconds 30

        Assert-Equal -Expected 126 -Actual $result.ExitCode -Message 'Output-limit exit code changed'
        Assert-True -Condition $result.OutputLimitExceeded -Message 'Output limit was not reported'
        Assert-True -Condition (-not $result.TimedOut) -Message 'Output limit was misclassified as a process timeout'
        Assert-True -Condition $result.TerminationSucceeded -Message 'Output-limit worker was not terminated'
        Assert-True -Condition $result.ContainmentApplied -Message 'Output-limit worker was not contained'
        Assert-True -Condition $result.TreeTerminationConfirmed -Message 'Output-limit tree termination was not confirmed'
        Assert-Equal -Expected '' -Actual $result.StandardOutput -Message 'Output-limit worker retained unbounded stdout'
        Assert-Equal -Expected '' -Actual $result.StandardError -Message 'Output-limit worker retained unbounded stderr'
        Assert-Equal -Expected 'output_limit' -Actual (Get-WorkerFailureKind -Result $result) -Message 'Output-limit failure classification changed'
        Assert-True -Condition ($result.DurationMs -lt 15000) -Message 'Output-limit worker returned too late'
    }

    Invoke-Test -Name 'Diagnostics redact an exact echoed work order without changing unrelated output' -Body {
        $workOrder = "sensitive work order`nunique-diagnostic-sentinel"
        $diagnostics = Get-SanitizedDiagnostics `
            -Text ("provider echoed: {0}`nother diagnostic" -f $workOrder) `
            -PromptText $workOrder

        Assert-True -Condition (-not $diagnostics.Contains('unique-diagnostic-sentinel')) -Message 'Echoed work order leaked into diagnostics'
        Assert-True -Condition $diagnostics.Contains('[REDACTED_WORK_ORDER]') -Message 'Echoed work order was not redacted'
        Assert-True -Condition $diagnostics.Contains('other diagnostic') -Message 'Unrelated diagnostics changed'
    }

    Invoke-Test -Name 'Planned worker startup failures remain structured execution failures' -Body {
        $missingPath = Join-Path $tempRoot 'missing-worker\claude.ps1'
        $plan = [pscustomobject]@{
            environmentOverlay = [pscustomobject]@{}
            filePath = $missingPath
            arguments = @('noop')
            workingDirectory = $tempRoot
            standardInputText = 'unused'
            allowBatchWorker = $false
        }
        $result = Invoke-AiwPlannedWorker `
            -Plan $plan `
            -TimeoutSeconds 10 `
            -TimeoutMilliseconds 10000

        Assert-Equal -Expected 126 -Actual $result.ExitCode -Message 'Startup failure exit code changed'
        Assert-Equal -Expected 'process_start_failed' -Actual (Get-WorkerFailureKind -Result $result) -Message 'Startup failure classification changed'
        Assert-Equal -Expected '' -Actual $result.StandardOutput -Message 'Startup failure returned output'
        Assert-True -Condition (-not $result.StandardError.Contains($missingPath)) -Message 'Startup failure leaked the configured path'
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
        Assert-Equal -Expected 2 -Actual $example.schemaVersion -Message 'Example schema version changed'
        Assert-True -Condition ($null -eq $example.defaultRoute) -Message 'Example config contains a default route'
        Assert-True -Condition ($null -eq $example.defaultProfile) -Message 'Example config contains a default profile'
        Assert-Equal -Expected 0 -Actual @($example.workers.PSObject.Properties).Count -Message 'Example config contains installed workers'
        Assert-Equal -Expected 0 -Actual @($example.profiles.PSObject.Properties).Count -Message 'Example config contains installed profiles'
        Assert-Equal -Expected 0 -Actual @($example.routes.PSObject.Properties).Count -Message 'Example config contains installed routes'
        $validation = Invoke-PublicConfigValidation -Path $examplePath
        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Neutral example failed public validation'
        Assert-True -Condition $validation.result.ok -Message 'Neutral example was rejected'
    }

    Invoke-Test -Name 'Published profile and showcase examples parse and validate without implicit defaults' -Body {
        foreach ($relativePath in @(
            'examples\profiles\supported-clis.example.json',
            'examples\showcases\maintainer-paid-plans.example.json'
        )) {
            $examplePath = Join-Path $orchestratorRoot $relativePath
            $example = Get-Content -Raw -LiteralPath $examplePath | ConvertFrom-Json
            Assert-Equal -Expected 2 -Actual $example.schemaVersion -Message ('Example schema version changed: {0}' -f $relativePath)
            Assert-True -Condition ($null -eq $example.defaultRoute) -Message ('Example contains a default route: {0}' -f $relativePath)
            Assert-True -Condition ($null -eq $example.defaultProfile) -Message ('Example contains a default profile: {0}' -f $relativePath)
            $validation = Invoke-PublicConfigValidation -Path $examplePath
            Assert-Equal -Expected 0 -Actual $validation.exitCode -Message ('Example failed public validation: {0}' -f $relativePath)
            Assert-True -Condition $validation.result.ok -Message ('Example was rejected: {0}' -f $relativePath)
        }
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
        $emptyUserProfile = Join-Path $tempRoot 'launcher-empty-user-profile'
        $missingWorkerPath = Join-Path $emptyUserProfile 'missing-worker.exe'
        [void](New-Item -ItemType Directory -Path $emptyUserProfile)
        $environmentNames = @(
            'USERPROFILE',
            'AIW_CONFIG_PATH',
            'AIW_ARK_PATH',
            'AIW_AGENT_PATH',
            'AIW_GOOGLE_PATH',
            'AIW_MINIMAX_PATH'
        )
        $previousEnvironment = @{}
        foreach ($name in $environmentNames) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        try {
            [Environment]::SetEnvironmentVariable('USERPROFILE', $emptyUserProfile, 'Process')
            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $null, 'Process')
            foreach ($name in @('AIW_ARK_PATH', 'AIW_AGENT_PATH', 'AIW_GOOGLE_PATH', 'AIW_MINIMAX_PATH')) {
                [Environment]::SetEnvironmentVariable($name, $missingWorkerPath, 'Process')
            }

            $launcherOutput = & $hostPath -NoLogo -NoProfile -NonInteractive -File $launcherPath status -Json
            $launcherExitCode = $LASTEXITCODE
            $launcherStatus = $launcherOutput | ConvertFrom-Json
        } finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
            }
        }

        Assert-Equal -Expected 0 -Actual $launcherExitCode -Message 'Launcher status returned a non-zero exit code without providers'
        Assert-Equal -Expected 'status' -Actual $launcherStatus.command -Message 'Launcher did not forward command'
        Assert-True -Condition $launcherStatus.ok -Message 'Launcher did not preserve JSON mode'
        Assert-Equal -Expected 4 -Actual @($launcherStatus.workers).Count -Message 'Launcher status worker inventory changed'
        $installedWorkers = @($launcherStatus.workers | Where-Object { $_.Installed })
        Assert-Equal -Expected 0 -Actual $installedWorkers.Count -Message 'Launcher reported a missing provider as installed'
    }

    Invoke-Test -Name 'PowerShell launcher returns zero after a successful worker' -Body {
        $fakeWorkerPath = Join-Path $tempRoot 'successful-worker.ps1'
        $configPath = Join-Path $tempRoot 'launcher-success-config.json'
        [System.IO.File]::WriteAllText(
            $fakeWorkerPath,
            '[void][Console]::In.ReadToEnd(); [Console]::Write(([char]123).ToString() + [char]34 + ''fixture'' + [char]34 + '':'' + ''true'' + [char]125)',
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

    Invoke-Test -Name 'Frozen v0.2 legacy commands preserve public golden contracts' -Body {
        $legacyRoot = Join-Path $tempRoot 'legacy-golden'
        $baselinePath = Join-Path $legacyRoot 'ai-workers-v0.2.0.ps1'
        $configPath = Join-Path $legacyRoot 'legacy-config.json'
        $claudePath = Join-Path $legacyRoot 'legacy-claude.ps1'
        $googlePath = Join-Path $legacyRoot 'legacy-agy.ps1'
        $miniMaxPath = Join-Path $legacyRoot 'legacy-mmx.ps1'
        $agentDirectory = Join-Path $legacyRoot 'agent-profile'
        $googleDirectory = Join-Path $legacyRoot 'google-profile'
        $arkSettingsPath = Join-Path $legacyRoot 'ark-settings.json'
        $miniMaxConfigPath = Join-Path $legacyRoot 'minimax-config.json'
        $failureClaudePath = Join-Path $legacyRoot 'legacy-failure-claude.ps1'
        $failureConfigPath = Join-Path $legacyRoot 'legacy-failure-config.json'
        $fallbackClaudePath = Join-Path $legacyRoot 'legacy-fallback-claude.ps1'
        $fallbackConfigPath = Join-Path $legacyRoot 'legacy-fallback-config.json'
        $overrideClaudePath = Join-Path $legacyRoot 'override-claude.ps1'
        $overrideGooglePath = Join-Path $legacyRoot 'override-google.ps1'
        $overrideMiniMaxPath = Join-Path $legacyRoot 'override-minimax.ps1'
        $advancedPromptPath = Join-Path $legacyRoot 'legacy-advanced-prompt.md'
        $diagnosticSentinel = 'V0_2_DIAGNOSTIC_SENTINEL'
        $hostPath = Get-CurrentPowerShellExecutable
        [void](New-Item -ItemType Directory -Path $legacyRoot)
        [void](New-Item -ItemType Directory -Path $agentDirectory)
        [void](New-Item -ItemType Directory -Path $googleDirectory)

        $expectedBaselineCommit = 'ecfa81a9b868a694067a1446bbdcdd2cb1da0a53'
        $baselineCommit = (@(& git -C $orchestratorRoot rev-parse 'v0.2.0^{commit}') -join '').Trim()
        Assert-Equal `
            -Expected $expectedBaselineCommit `
            -Actual $baselineCommit `
            -Message 'The v0.2.0 golden baseline tag no longer resolves to its immutable release commit'
        $baselineSource = @(& git -C $orchestratorRoot show ('{0}:ai-workers.ps1' -f $baselineCommit))
        if ($LASTEXITCODE -ne 0 -or $baselineSource.Count -eq 0) {
            throw 'Could not load the frozen v0.2.0 dispatcher source for golden compatibility testing.'
        }
        [System.IO.File]::WriteAllText(
            $baselinePath,
            ($baselineSource -join [Environment]::NewLine),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $claudeFixture = @'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$model = $null
$permission = $null
$tools = $null
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -eq '--model') { $model = $args[$index + 1] }
    if ($args[$index] -eq '--permission-mode') { $permission = $args[$index + 1] }
    if ($args[$index] -eq '--tools') { $tools = $args[$index + 1] }
}
[pscustomobject]@{
    fixture = 'claude'
    model = $model
    permission = $permission
    tools = $tools
    apiTimeout = [string]$env:API_TIMEOUT_MS
    profileDirectory = [string]$env:CLAUDE_CONFIG_DIR
    workingDirectory = (Get-Location).Path
    prompt = [Console]::In.ReadToEnd()
} | ConvertTo-Json -Compress
'@
        $googleFixture = @'
$model = $null
$mode = $null
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -eq '--model') { $model = $args[$index + 1] }
    if ($args[$index] -eq '--mode') { $mode = $args[$index + 1] }
}
[pscustomobject]@{
    fixture = 'google'
    model = $model
    mode = $mode
    sandbox = [bool]($args -contains '--sandbox')
} | ConvertTo-Json -Compress
'@
        $miniMaxFixture = @'
$model = $null
$message = $null
$kind = if ($args -contains 'quota') { 'quota' } else { 'text' }
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -eq '--model') { $model = $args[$index + 1] }
    if ($args[$index] -eq '--messages-file') {
        $messages = Get-Content -Raw -LiteralPath $args[$index + 1] | ConvertFrom-Json
        $message = $messages[0].content
    }
}
[pscustomobject]@{
    fixture = 'minimax'
    kind = $kind
    model = $model
    prompt = $message
    baseUrl = [string]$env:MINIMAX_BASE_URL
    configDirectory = [string]$env:MMX_CONFIG_DIR
} | ConvertTo-Json -Compress
'@
        [System.IO.File]::WriteAllText($claudePath, $claudeFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($googlePath, $googleFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($miniMaxPath, $miniMaxFixture, (New-Object System.Text.UTF8Encoding($false)))
        $fallbackClaudeFixture = @'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[void][Console]::In.ReadToEnd()
$model = $null
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -eq '--model') { $model = $args[$index + 1] }
}
if ($model -eq 'glm-5.2') { exit 9 }
[pscustomobject]@{ fixture = 'fallback'; model = $model } | ConvertTo-Json -Compress
'@
        [System.IO.File]::WriteAllText($fallbackClaudePath, $fallbackClaudeFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText(
            $failureClaudePath,
            ('[void][Console]::In.ReadToEnd(); [Console]::Error.Write(''{0}''); exit 9' -f $diagnosticSentinel),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $overrideClaudeFixture = @'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[void][Console]::In.ReadToEnd()
[pscustomobject]@{ fixture = 'override-claude' } | ConvertTo-Json -Compress
'@
        $overrideGoogleFixture = "[pscustomobject]@{ fixture = 'override-google' } | ConvertTo-Json -Compress"
        $overrideMiniMaxFixture = "[pscustomobject]@{ fixture = 'override-minimax' } | ConvertTo-Json -Compress"
        [System.IO.File]::WriteAllText($overrideClaudePath, $overrideClaudeFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($overrideGooglePath, $overrideGoogleFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($overrideMiniMaxPath, $overrideMiniMaxFixture, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText(
            $advancedPromptPath,
            ('legacy prompt file' + [Environment]::NewLine + 'line 2 "quoted" slash\'),
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-TestJson -Path $arkSettingsPath -Value ([ordered]@{
            env = [ordered]@{
                ANTHROPIC_BASE_URL = 'https://fixture.invalid'
                ANTHROPIC_AUTH_TOKEN = 'fixture-token'
                ANTHROPIC_MODEL = 'legacy-ark'
            }
        })
        Write-TestJson -Path (Join-Path $agentDirectory 'settings.json') -Value ([ordered]@{
            env = [ordered]@{
                ANTHROPIC_BASE_URL = 'https://fixture.invalid'
                ANTHROPIC_AUTH_TOKEN = 'fixture-token'
                ANTHROPIC_MODEL = 'legacy-agent'
            }
        })
        Write-TestJson -Path $miniMaxConfigPath -Value ([ordered]@{
            api_key = 'fixture-token'
            region = 'fixture'
        })
        Write-TestJson -Path $configPath -Value ([ordered]@{
            workers = [ordered]@{
                ark = [ordered]@{
                    path = $claudePath
                    model = 'legacy-ark'
                    configPath = $arkSettingsPath
                }
                agent = [ordered]@{
                    path = $claudePath
                    model = 'legacy-agent'
                    configDirectory = $agentDirectory
                }
                google = [ordered]@{
                    path = $googlePath
                    model = 'legacy-google'
                    configDirectory = $googleDirectory
                }
                minimax = [ordered]@{
                    path = $miniMaxPath
                    model = 'legacy-minimax'
                    configPath = $miniMaxConfigPath
                    baseUrl = 'https://api.minimaxi.com'
                    quotaBaseUrl = 'https://www.minimaxi.com'
                }
            }
        })
        Write-TestJson -Path $failureConfigPath -Value ([ordered]@{
            workers = [ordered]@{
                ark = [ordered]@{
                    path = $failureClaudePath
                    model = 'legacy-ark'
                    configPath = $arkSettingsPath
                }
            }
        })
        Write-TestJson -Path $fallbackConfigPath -Value ([ordered]@{
            workers = [ordered]@{
                ark = [ordered]@{
                    path = $fallbackClaudePath
                    model = 'glm-5.2'
                    configPath = $arkSettingsPath
                }
            }
        })

        $overrideNames = @('AIW_CONFIG_PATH', 'AIW_ARK_PATH', 'AIW_AGENT_PATH', 'AIW_GOOGLE_PATH', 'AIW_MINIMAX_PATH')
        $previousOverrides = @{}
        foreach ($name in $overrideNames) {
            $previousOverrides[$name] = [Environment]::GetEnvironmentVariable($name)
            Remove-Item -LiteralPath ('Env:{0}' -f $name) -ErrorAction SilentlyContinue
        }
        try {
            foreach ($commandName in @('status', 'doctor', 'ark', 'agent', 'google', 'minimax', 'quota')) {
                $baseline = Invoke-LegacyGoldenCommand `
                    -HostPath $hostPath `
                    -ScriptPath $baselinePath `
                    -CommandName $commandName `
                    -ConfigPath $configPath `
                    -WorkingDirectory $legacyRoot `
                    -Json
                $currentDefault = Invoke-LegacyGoldenCommand `
                    -HostPath $hostPath `
                    -ScriptPath $sutPath `
                    -CommandName $commandName `
                    -ConfigPath $configPath `
                    -WorkingDirectory $legacyRoot `
                    -Json
                $currentExplicit = Invoke-LegacyGoldenCommand `
                    -HostPath $hostPath `
                    -ScriptPath $sutPath `
                    -CommandName $commandName `
                    -ConfigPath $configPath `
                    -WorkingDirectory $legacyRoot `
                    -Json `
                    -ExplicitOutputSchema

                Assert-Equal -Expected 0 -Actual $baseline.exitCode -Message ('Frozen v0.2 command failed: {0}' -f $commandName)
                Assert-Equal -Expected $baseline.exitCode -Actual $currentDefault.exitCode -Message ('Legacy default exit code changed: {0}' -f $commandName)
                Assert-Equal -Expected $currentDefault.exitCode -Actual $currentExplicit.exitCode -Message ('Explicit schema 1 exit code changed: {0}' -f $commandName)
                $baselineJson = $baseline.text | ConvertFrom-Json
                $currentDefaultJson = $currentDefault.text | ConvertFrom-Json
                $currentExplicitJson = $currentExplicit.text | ConvertFrom-Json
                Assert-Equal -Expected 1 -Actual $currentDefaultJson.schemaVersion -Message ('Legacy default schema changed: {0}' -f $commandName)
                Assert-Equal -Expected 1 -Actual $currentExplicitJson.schemaVersion -Message ('Explicit schema 1 changed: {0}' -f $commandName)
                Assert-True -Condition ($null -eq $currentDefaultJson.PSObject.Properties['productVersion']) -Message ('Legacy default gained productVersion: {0}' -f $commandName)
                Assert-True -Condition ($null -eq $currentExplicitJson.PSObject.Properties['productVersion']) -Message ('Explicit schema 1 gained productVersion: {0}' -f $commandName)
                Assert-Equal `
                    -Expected (ConvertTo-LegacyComparableJson -Result $baselineJson) `
                    -Actual (ConvertTo-LegacyComparableJson -Result $currentDefaultJson) `
                    -Message ('Legacy JSON golden contract changed: {0}' -f $commandName)
                Assert-Equal `
                    -Expected (ConvertTo-LegacyComparableJson -Result $currentDefaultJson) `
                    -Actual (ConvertTo-LegacyComparableJson -Result $currentExplicitJson) `
                    -Message ('Explicit schema 1 JSON contract changed: {0}' -f $commandName)

                $baselineText = Invoke-LegacyGoldenCommand `
                    -HostPath $hostPath `
                    -ScriptPath $baselinePath `
                    -CommandName $commandName `
                    -ConfigPath $configPath `
                    -WorkingDirectory $legacyRoot
                $currentText = Invoke-LegacyGoldenCommand `
                    -HostPath $hostPath `
                    -ScriptPath $sutPath `
                    -CommandName $commandName `
                    -ConfigPath $configPath `
                    -WorkingDirectory $legacyRoot
                Assert-Equal -Expected $baselineText.exitCode -Actual $currentText.exitCode -Message ('Legacy text exit code changed: {0}' -f $commandName)
                Assert-Equal -Expected $baselineText.text -Actual $currentText.text -Message ('Legacy text golden contract changed: {0}' -f $commandName)
            }

            $largePromptRangeBaseline = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $baselinePath `
                -CommandName 'status' `
                -ConfigPath $configPath `
                -WorkingDirectory $legacyRoot `
                -MaxPromptBytes 1048577 `
                -Json
            $largePromptRangeCurrent = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $sutPath `
                -CommandName 'status' `
                -ConfigPath $configPath `
                -WorkingDirectory $legacyRoot `
                -MaxPromptBytes 1048577 `
                -Json
            Assert-Equal -Expected $largePromptRangeBaseline.exitCode -Actual $largePromptRangeCurrent.exitCode -Message 'Legacy large MaxPromptBytes binding changed'
            Assert-Equal `
                -Expected (ConvertTo-LegacyComparableJson -Result ($largePromptRangeBaseline.text | ConvertFrom-Json)) `
                -Actual (ConvertTo-LegacyComparableJson -Result ($largePromptRangeCurrent.text | ConvertFrom-Json)) `
                -Message 'Legacy large MaxPromptBytes result changed'

            $advancedCases = @(
                [pscustomobject]@{ command = 'ark'; mode = 'write'; model = 'golden-ark-write'; googleModel = $null; agentModel = $null },
                [pscustomobject]@{ command = 'agent'; mode = 'write'; model = $null; googleModel = $null; agentModel = 'golden-agent-write' },
                [pscustomobject]@{ command = 'google'; mode = 'write'; model = $null; googleModel = 'golden-google-write'; agentModel = $null },
                [pscustomobject]@{ command = 'minimax'; mode = 'read'; model = 'golden-minimax-read'; googleModel = $null; agentModel = $null }
            )
            foreach ($case in $advancedCases) {
                $goldenCommon = @{
                    HostPath = $hostPath
                    CommandName = $case.command
                    ConfigPath = $configPath
                    WorkingDirectory = $legacyRoot
                    PromptFile = $advancedPromptPath
                    Mode = $case.mode
                    Model = $case.model
                    GoogleModel = $case.googleModel
                    AgentModel = $case.agentModel
                    MaxPromptBytes = 4096
                    Json = $true
                }

                $advancedBaseline = Invoke-LegacyGoldenCommand -ScriptPath $baselinePath @goldenCommon
                $advancedCurrent = Invoke-LegacyGoldenCommand -ScriptPath $sutPath @goldenCommon
                $advancedExplicit = Invoke-LegacyGoldenCommand -ScriptPath $sutPath -ExplicitOutputSchema @goldenCommon
                Assert-Equal -Expected 0 -Actual $advancedBaseline.exitCode -Message ('Frozen v0.2 advanced command failed: {0}' -f $case.command)
                Assert-Equal -Expected $advancedBaseline.exitCode -Actual $advancedCurrent.exitCode -Message ('Legacy advanced exit code changed: {0}' -f $case.command)
                Assert-Equal -Expected $advancedCurrent.exitCode -Actual $advancedExplicit.exitCode -Message ('Explicit schema 1 advanced exit code changed: {0}' -f $case.command)
                $advancedBaselineJson = $advancedBaseline.text | ConvertFrom-Json
                $advancedCurrentJson = $advancedCurrent.text | ConvertFrom-Json
                $advancedExplicitJson = $advancedExplicit.text | ConvertFrom-Json
                Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $advancedBaselineJson) -Actual (ConvertTo-LegacyComparableJson -Result $advancedCurrentJson) -Message ('Legacy advanced JSON contract changed: {0}' -f $case.command)
                Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $advancedCurrentJson) -Actual (ConvertTo-LegacyComparableJson -Result $advancedExplicitJson) -Message ('Explicit schema 1 advanced JSON contract changed: {0}' -f $case.command)
            }

            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $configPath, 'Process')
            try {
                $defaultBaseline = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $baselinePath -CommandName 'ark' -PromptText 'legacy defaults' -UseDefaultMode -UseDefaultTimeout -Json
                $defaultCurrent = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $sutPath -CommandName 'ark' -PromptText 'legacy defaults' -UseDefaultMode -UseDefaultTimeout -Json
            } finally {
                [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $null, 'Process')
            }
            Assert-Equal -Expected 0 -Actual $defaultBaseline.exitCode -Message 'Frozen v0.2 environment/default command failed'
            Assert-Equal -Expected $defaultBaseline.exitCode -Actual $defaultCurrent.exitCode -Message 'Legacy environment/default exit code changed'
            $defaultBaselineJson = $defaultBaseline.text | ConvertFrom-Json
            $defaultCurrentJson = $defaultCurrent.text | ConvertFrom-Json
            Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $defaultBaselineJson) -Actual (ConvertTo-LegacyComparableJson -Result $defaultCurrentJson) -Message 'AIW_CONFIG_PATH or legacy defaults changed'

            $pathOverrideCases = @(
                [pscustomobject]@{ environment = 'AIW_ARK_PATH'; command = 'ark'; path = $overrideClaudePath; fixture = 'override-claude' },
                [pscustomobject]@{ environment = 'AIW_AGENT_PATH'; command = 'agent'; path = $overrideClaudePath; fixture = 'override-claude' },
                [pscustomobject]@{ environment = 'AIW_GOOGLE_PATH'; command = 'google'; path = $overrideGooglePath; fixture = 'override-google' },
                [pscustomobject]@{ environment = 'AIW_MINIMAX_PATH'; command = 'minimax'; path = $overrideMiniMaxPath; fixture = 'override-minimax' }
            )
            foreach ($overrideCase in $pathOverrideCases) {
                [Environment]::SetEnvironmentVariable($overrideCase.environment, $overrideCase.path, 'Process')
                try {
                    $overrideBaseline = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $baselinePath -CommandName $overrideCase.command -ConfigPath $configPath -WorkingDirectory $legacyRoot -Json
                    $overrideCurrent = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $sutPath -CommandName $overrideCase.command -ConfigPath $configPath -WorkingDirectory $legacyRoot -Json
                } finally {
                    [Environment]::SetEnvironmentVariable($overrideCase.environment, $null, 'Process')
                }
                Assert-Equal -Expected 0 -Actual $overrideBaseline.exitCode -Message ('Frozen v0.2 path override failed: {0}' -f $overrideCase.environment)
                Assert-Equal -Expected $overrideBaseline.exitCode -Actual $overrideCurrent.exitCode -Message ('Legacy path override exit code changed: {0}' -f $overrideCase.environment)
                $overrideBaselineJson = $overrideBaseline.text | ConvertFrom-Json
                $overrideCurrentJson = $overrideCurrent.text | ConvertFrom-Json
                Assert-Equal -Expected $overrideCase.fixture -Actual $overrideCurrentJson.output.fixture -Message ('Legacy path override was not used: {0}' -f $overrideCase.environment)
                Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $overrideBaselineJson) -Actual (ConvertTo-LegacyComparableJson -Result $overrideCurrentJson) -Message ('Legacy path override contract changed: {0}' -f $overrideCase.environment)
            }

            $noFallbackBaseline = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $baselinePath -CommandName 'ark' -ConfigPath $fallbackConfigPath -WorkingDirectory $legacyRoot -NoFallback -Json
            $noFallbackCurrent = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $sutPath -CommandName 'ark' -ConfigPath $fallbackConfigPath -WorkingDirectory $legacyRoot -NoFallback -Json
            Assert-Equal -Expected 9 -Actual $noFallbackBaseline.exitCode -Message 'Frozen v0.2 NoFallback fixture did not stop after the primary failure'
            Assert-Equal -Expected $noFallbackBaseline.exitCode -Actual $noFallbackCurrent.exitCode -Message 'Legacy NoFallback exit code changed'
            $noFallbackBaselineJson = $noFallbackBaseline.text | ConvertFrom-Json
            $noFallbackCurrentJson = $noFallbackCurrent.text | ConvertFrom-Json
            Assert-Equal -Expected 1 -Actual @($noFallbackCurrentJson.attempts).Count -Message 'Legacy NoFallback started more than one attempt'
            Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $noFallbackBaselineJson) -Actual (ConvertTo-LegacyComparableJson -Result $noFallbackCurrentJson) -Message 'Legacy NoFallback contract changed'

            $fallbackBaseline = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $baselinePath -CommandName 'ark' -ConfigPath $fallbackConfigPath -WorkingDirectory $legacyRoot -Json
            $fallbackCurrent = Invoke-LegacyGoldenCommand -HostPath $hostPath -ScriptPath $sutPath -CommandName 'ark' -ConfigPath $fallbackConfigPath -WorkingDirectory $legacyRoot -Json
            Assert-Equal -Expected 0 -Actual $fallbackBaseline.exitCode -Message 'Frozen v0.2 fallback fixture did not recover'
            Assert-Equal -Expected $fallbackBaseline.exitCode -Actual $fallbackCurrent.exitCode -Message 'Legacy fallback exit code changed'
            $fallbackBaselineJson = $fallbackBaseline.text | ConvertFrom-Json
            $fallbackCurrentJson = $fallbackCurrent.text | ConvertFrom-Json
            Assert-Equal -Expected 2 -Actual @($fallbackCurrentJson.attempts).Count -Message 'Legacy fallback attempt count changed'
            Assert-Equal -Expected 'kimi-k2.7-code' -Actual $fallbackCurrentJson.model -Message 'Legacy fallback model changed'
            Assert-Equal -Expected (ConvertTo-LegacyComparableJson -Result $fallbackBaselineJson) -Actual (ConvertTo-LegacyComparableJson -Result $fallbackCurrentJson) -Message 'Legacy fallback contract changed'

            $failureBaseline = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $baselinePath `
                -CommandName 'ark' `
                -ConfigPath $failureConfigPath `
                -WorkingDirectory $legacyRoot `
                -PromptText 'legacy failure prompt' `
                -Json
            $failureCurrentDefault = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $sutPath `
                -CommandName 'ark' `
                -ConfigPath $failureConfigPath `
                -WorkingDirectory $legacyRoot `
                -PromptText 'legacy failure prompt' `
                -Json
            $failureCurrentExplicit = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $sutPath `
                -CommandName 'ark' `
                -ConfigPath $failureConfigPath `
                -WorkingDirectory $legacyRoot `
                -PromptText 'legacy failure prompt' `
                -Json `
                -ExplicitOutputSchema
            Assert-Equal -Expected 9 -Actual $failureBaseline.exitCode -Message 'Frozen v0.2 failure fixture did not fail as expected'
            Assert-Equal -Expected 9 -Actual $failureCurrentDefault.exitCode -Message 'Legacy failure exit code changed'
            Assert-Equal -Expected 9 -Actual $failureCurrentExplicit.exitCode -Message 'Explicit schema 1 failure exit code changed'
            $failureBaselineJson = $failureBaseline.text | ConvertFrom-Json
            $failureCurrentDefaultJson = $failureCurrentDefault.text | ConvertFrom-Json
            $failureCurrentExplicitJson = $failureCurrentExplicit.text | ConvertFrom-Json
            Assert-True -Condition ($null -eq $failureCurrentDefaultJson.PSObject.Properties['productVersion']) -Message 'Legacy failure gained productVersion'
            Assert-True -Condition ($null -eq $failureCurrentExplicitJson.PSObject.Properties['productVersion']) -Message 'Explicit schema 1 failure gained productVersion'
            Assert-True -Condition ([string]$failureBaselineJson.diagnostics).Contains($diagnosticSentinel) -Message 'The v0.2 failure fixture did not expose its baseline diagnostic sentinel'
            Assert-True -Condition (-not ([string]$failureCurrentDefaultJson.diagnostics).Contains($diagnosticSentinel)) -Message 'Legacy v0.3 JSON diagnostics leaked provider stderr'
            Assert-True -Condition (-not ([string]$failureCurrentExplicitJson.diagnostics).Contains($diagnosticSentinel)) -Message 'Explicit schema 1 JSON diagnostics leaked provider stderr'
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$failureCurrentDefaultJson.diagnostics)) -Message 'Legacy v0.3 did not return a generic withheld diagnostic'
            Assert-Equal `
                -Expected (ConvertTo-LegacyComparableJson -Result $failureBaselineJson -IgnoreDiagnostics) `
                -Actual (ConvertTo-LegacyComparableJson -Result $failureCurrentDefaultJson -IgnoreDiagnostics) `
                -Message 'Legacy failure behavior changed beyond the documented diagnostics hardening'
            Assert-Equal `
                -Expected (ConvertTo-LegacyComparableJson -Result $failureCurrentDefaultJson) `
                -Actual (ConvertTo-LegacyComparableJson -Result $failureCurrentExplicitJson) `
                -Message 'Explicit schema 1 failure projection changed'

            $failureBaselineText = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $baselinePath `
                -CommandName 'ark' `
                -ConfigPath $failureConfigPath `
                -WorkingDirectory $legacyRoot `
                -PromptText 'legacy failure prompt'
            $failureCurrentText = Invoke-LegacyGoldenCommand `
                -HostPath $hostPath `
                -ScriptPath $sutPath `
                -CommandName 'ark' `
                -ConfigPath $failureConfigPath `
                -WorkingDirectory $legacyRoot `
                -PromptText 'legacy failure prompt'
            Assert-Equal -Expected 9 -Actual $failureBaselineText.exitCode -Message 'Frozen v0.2 text failure fixture did not fail as expected'
            Assert-Equal -Expected 9 -Actual $failureCurrentText.exitCode -Message 'Legacy text failure exit code changed'
            Assert-True -Condition $failureBaselineText.text.Contains($diagnosticSentinel) -Message 'The v0.2 text failure fixture did not expose its diagnostic sentinel'
            Assert-True -Condition (-not $failureCurrentText.text.Contains($diagnosticSentinel)) -Message 'Legacy v0.3 text diagnostics leaked provider stderr'
        } finally {
            foreach ($name in $overrideNames) {
                Restore-EnvironmentVariable -Name $name -PreviousValue $previousOverrides[$name]
            }
        }
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
        Assert-Equal -Expected $script:ExpectedProductVersion -Actual $catalog.productVersion -Message 'Catalog product version changed'
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
        Assert-Equal -Expected $script:ExpectedProductVersion -Actual $validation.productVersion -Message 'Config product version changed'
        Assert-True -Condition $validation.ok -Message 'Neutral config was rejected'
        Assert-Equal -Expected 'config' -Actual $validation.command -Message 'Config command name changed'
        Assert-Equal -Expected 'validate' -Actual $validation.action -Message 'Config action changed'
        Assert-Equal -Expected 2 -Actual $validation.configSchemaVersion -Message 'Config schema was not reported'
        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Config payload exit code changed'
        Assert-Equal -Expected 0 -Actual @($validation.errors).Count -Message 'Neutral config returned validation errors'
    }

    Invoke-Test -Name 'V2 commands resolve AIW_CONFIG_PATH when ConfigPath is omitted' -Body {
        $configPath = Join-Path $tempRoot 'environment-config-v2.json'
        Write-TestJson -Path $configPath -Value ([ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{}
            profiles = [ordered]@{}
            routes = [ordered]@{}
        })
        $previousConfigPath = [Environment]::GetEnvironmentVariable('AIW_CONFIG_PATH', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $configPath, 'Process')
            $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
            $hostPath = Get-CurrentPowerShellExecutable
            $validationOutput = & $hostPath `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -File $launcherPath `
                config `
                -Action validate `
                -Json
            $validationExitCode = $LASTEXITCODE
            $validation = (@($validationOutput) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 0 -Actual $validationExitCode -Message 'AIW_CONFIG_PATH validation returned a non-zero exit code'
            Assert-True -Condition $validation.ok -Message 'AIW_CONFIG_PATH configuration was not used'
            Assert-Equal -Expected $configPath -Actual $validation.configPath -Message 'AIW_CONFIG_PATH resolved to the wrong config file'
        } finally {
            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $previousConfigPath, 'Process')
        }
    }

    Invoke-Test -Name 'V2 status discovers a local Claude worker without creating configuration or provider priority' -Body {
        $discoveryDirectory = Join-Path $tempRoot 'discovery-bin'
        $discoveredWorkerPath = Join-Path $discoveryDirectory 'claude.ps1'
        $promptPath = Join-Path $tempRoot 'discovery-prompt.md'
        [void](New-Item -ItemType Directory -Path $discoveryDirectory)
        [System.IO.File]::WriteAllText(
            $discoveredWorkerPath,
            '[Console]::Write([Console]::In.ReadToEnd())',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'discovery prompt')
        $previousPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
        $previousUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
        $previousConfigPath = [Environment]::GetEnvironmentVariable('AIW_CONFIG_PATH', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('Path', $discoveryDirectory, 'Process')
            [Environment]::SetEnvironmentVariable('USERPROFILE', $tempRoot, 'Process')
            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $null, 'Process')
            $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
            $hostPath = Get-CurrentPowerShellExecutable
            $statusOutput = & $hostPath `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -File $launcherPath `
                status `
                -OutputSchema 2 `
                -Json
            $statusExitCode = $LASTEXITCODE
            $status = (@($statusOutput) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 0 -Actual $statusExitCode -Message 'Discovered status returned a non-zero exit code'
            Assert-True -Condition $status.ok -Message 'Discovered status failed'
            Assert-Equal -Expected 2 -Actual $status.schemaVersion -Message 'Discovered status schema changed'
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual $status.productVersion -Message 'Discovered status product version changed'
            Assert-True -Condition (-not $status.configLoaded) -Message 'Discovery unexpectedly loaded a configuration'
            Assert-Equal -Expected 'discovered' -Actual $status.provenance -Message 'Discovery provenance changed'
            Assert-Equal -Expected 'discovered-claude-code' -Actual $status.workers[0].worker -Message 'Discovered worker ID changed'
            Assert-True -Condition ($null -eq $status.workers[0].model) -Message 'Discovery unexpectedly pinned a model'

            $runOutput = & $hostPath `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -File $launcherPath `
                run `
                -Worker 'discovered-claude-code' `
                -PromptFile $promptPath `
                -Mode read `
                -WorkingDirectory $tempRoot `
                -TimeoutSeconds 30 `
                -Json
            $runExitCode = $LASTEXITCODE
            $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json
            Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Discovered worker run returned a non-zero exit code'
            Assert-True -Condition $run.ok -Message 'Discovered worker run failed'
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual $run.productVersion -Message 'Run product version changed'
            Assert-Equal -Expected 'discovered-claude-code' -Actual $run.selection.worker -Message 'Discovered run selected the wrong worker'
            Assert-True -Condition ($null -eq $run.selection.model) -Message 'Discovered run unexpectedly pinned a model'
            Assert-Equal -Expected 'discovery prompt' -Actual $run.output -Message 'Discovered worker changed the prompt'
        } finally {
            [Environment]::SetEnvironmentVariable('Path', $previousPath, 'Process')
            [Environment]::SetEnvironmentVariable('USERPROFILE', $previousUserProfile, 'Process')
            [Environment]::SetEnvironmentVariable('AIW_CONFIG_PATH', $previousConfigPath, 'Process')
        }
    }

    Invoke-Test -Name 'Healthy explicit V2 status and doctor preserve an empty warnings array' -Body {
        $configPath = Join-Path $orchestratorRoot 'config.example.json'
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        foreach ($commandName in @('status', 'doctor')) {
            $inventoryOutput = & $hostPath `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -File $launcherPath `
                $commandName `
                -OutputSchema 2 `
                -ConfigPath $configPath `
                -Json
            $inventoryExitCode = $LASTEXITCODE
            $inventoryText = @($inventoryOutput) -join [Environment]::NewLine
            $inventory = $inventoryText | ConvertFrom-Json

            Assert-Equal -Expected 0 -Actual $inventoryExitCode -Message ('Healthy v2 {0} returned a non-zero exit code' -f $commandName)
            Assert-True -Condition $inventory.ok -Message ('Healthy v2 {0} failed' -f $commandName)
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual $inventory.productVersion -Message ('Healthy v2 {0} product version changed' -f $commandName)
            Assert-True -Condition ($inventoryText -match '"warnings"\s*:\s*\[') -Message ('Healthy v2 {0} warnings did not serialize as an array' -f $commandName)
            Assert-Equal -Expected 0 -Actual @($inventory.warnings).Count -Message ('Healthy v2 {0} warnings changed' -f $commandName)
        }
    }

    Invoke-Test -Name 'V2 inventory projects omitted optional profile and route fields with stable defaults' -Body {
        $fixtureDirectory = Join-Path $tempRoot 'inventory-optional-fields'
        $workerPath = Join-Path $fixtureDirectory 'claude.ps1'
        $configPath = Join-Path $tempRoot 'inventory-optional-fields-v2.json'
        [void](New-Item -ItemType Directory -Path $fixtureDirectory)
        [System.IO.File]::WriteAllText(
            $workerPath,
            '[Console]::Write(''inventory fixture'')',
            (New-Object System.Text.UTF8Encoding($false))
        )
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $workerPath
        [void]$config.profiles.standard.Remove('fallback')
        foreach ($field in @('requiredCapabilities', 'defaultMode', 'allowedModes')) {
            [void]$config.routes.review.Remove($field)
        }
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable

        foreach ($commandName in @('status', 'doctor')) {
            $inventoryOutput = & $hostPath -NoLogo -NoProfile -NonInteractive -File $launcherPath $commandName -OutputSchema 2 -ConfigPath $configPath -Json
            $inventoryExitCode = $LASTEXITCODE
            $inventory = (@($inventoryOutput) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 0 -Actual $inventoryExitCode -Message ('Optional-field v2 {0} returned a non-zero exit code' -f $commandName)
            Assert-True -Condition $inventory.ok -Message ('Optional-field v2 {0} failed' -f $commandName)
            Assert-Equal -Expected 1 -Actual $inventory.profiles[0].fallback.maxAttempts -Message ('Optional profile fallback maxAttempts changed: {0}' -f $commandName)
            Assert-Equal -Expected 0 -Actual @($inventory.profiles[0].fallback.on).Count -Message ('Optional profile fallback kinds changed: {0}' -f $commandName)
            Assert-Equal -Expected 0 -Actual @($inventory.routes[0].requiredCapabilities).Count -Message ('Optional route capabilities changed: {0}' -f $commandName)
            Assert-Equal -Expected 'read' -Actual $inventory.routes[0].defaultMode -Message ('Optional route default mode changed: {0}' -f $commandName)
            Assert-Equal -Expected 'read' -Actual $inventory.routes[0].allowedModes[0] -Message ('Optional route allowed mode changed: {0}' -f $commandName)
        }
    }

    Invoke-Test -Name 'V2 null optional fields normalize to omitted defaults for inventory and run planning' -Body {
        $fixtureDirectory = Join-Path $tempRoot 'null-optional-fields'
        $workerPath = Join-Path $fixtureDirectory 'claude.ps1'
        $configPath = Join-Path $tempRoot 'null-optional-fields-v2.json'
        $promptPath = Join-Path $tempRoot 'null-optional-fields-prompt.md'
        [void](New-Item -ItemType Directory -Path $fixtureDirectory)
        [System.IO.File]::WriteAllText(
            $workerPath,
            '[Console]::Write([Console]::In.ReadToEnd())',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'null optional fields prompt')
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $workerPath
        $config.workers.fixture.capabilities = $null
        $config.profiles.standard.fallback = $null
        $config.routes.review.requiredCapabilities = $null
        $config.routes.review.defaultMode = $null
        $config.routes.review.allowedModes = $null
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable

        $validation = Invoke-PublicConfigValidation -Path $configPath
        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Null optional config did not validate'

        $statusOutput = & $hostPath -NoLogo -NoProfile -NonInteractive -File $launcherPath status -OutputSchema 2 -ConfigPath $configPath -Json
        $statusExitCode = $LASTEXITCODE
        $status = (@($statusOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal -Expected 0 -Actual $statusExitCode -Message 'Null optional status returned a non-zero exit code'
        Assert-Equal -Expected 1 -Actual $status.profiles[0].fallback.maxAttempts -Message 'Null fallback maxAttempts changed'
        Assert-Equal -Expected 0 -Actual @($status.routes[0].requiredCapabilities).Count -Message 'Null route capabilities changed'
        Assert-Equal -Expected 'read' -Actual $status.routes[0].defaultMode -Message 'Null route default mode changed'
        Assert-Equal -Expected 'read' -Actual $status.routes[0].allowedModes[0] -Message 'Null route allowed modes changed'
        Assert-True -Condition (@($status.workers[0].capabilities).Count -gt 0) -Message 'Null worker capabilities did not inherit adapter capabilities'

        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Route review `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Null optional route run returned a non-zero exit code'
        Assert-True -Condition $run.ok -Message 'Null optional route run failed'
        Assert-Equal -Expected 'null optional fields prompt' -Actual $run.output -Message 'Null optional route prompt changed'
    }

    Invoke-Test -Name 'Core run planning is filesystem-side-effect free for controlled artifacts' -Body {
        $fixtureDirectory = Join-Path $tempRoot 'artifact-plan-fixtures'
        [void](New-Item -ItemType Directory -Path $fixtureDirectory)
        $cases = @(
            [pscustomobject]@{
                adapter = 'antigravity/v1'
                launcher = 'agy.ps1'
                kind = 'antigravity-work-order'
                pattern = 'aiw-google-*'
                settings = [ordered]@{}
            },
            [pscustomobject]@{
                adapter = 'minimax-cli/v1'
                launcher = 'mmx.ps1'
                kind = 'minimax-messages'
                pattern = 'aiw-minimax-*'
                settings = [ordered]@{ region = 'cn' }
            }
        )

        foreach ($case in $cases) {
            $workerPath = Join-Path $fixtureDirectory $case.launcher
            $configPath = Join-Path $fixtureDirectory (
                '{0}.json' -f $case.kind
            )
            [System.IO.File]::WriteAllText($workerPath, '[Console]::Write(''unused'')')
            Write-TestJson -Path $configPath -Value ([ordered]@{
                schemaVersion = 2
                defaultRoute = $null
                defaultProfile = $null
                workers = [ordered]@{
                    fixture = [ordered]@{
                        adapter = $case.adapter
                        enabled = $true
                        path = $workerPath
                        model = 'fixture-model'
                        capabilities = @('text.reason')
                        settings = $case.settings
                    }
                }
                profiles = [ordered]@{}
                routes = [ordered]@{}
            })
            $before = @(
                Get-ChildItem `
                    -LiteralPath ([System.IO.Path]::GetTempPath()) `
                    -Directory `
                    -Filter $case.pattern `
                    -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName |
                        Sort-Object
            )
            $planResult = Invoke-AiwCore -Request ([pscustomobject]@{
                command = 'run.plan'
                configPath = $configPath
                worker = 'fixture'
                profile = $null
                route = $null
                mode = 'read'
                requiredCapabilities = @()
                promptText = 'planning must not touch the filesystem'
                workingDirectory = $tempRoot
                timeoutSeconds = 30
                noFallback = $true
            })
            $after = @(
                Get-ChildItem `
                    -LiteralPath ([System.IO.Path]::GetTempPath()) `
                    -Directory `
                    -Filter $case.pattern `
                    -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName |
                        Sort-Object
            )

            Assert-True -Condition $planResult.ok -Message ('Artifact planning failed: {0}' -f $case.kind)
            Assert-Equal -Expected $case.kind -Actual $planResult.plan.artifact.kind -Message ('Artifact plan kind changed: {0}' -f $case.kind)
            Assert-True -Condition ($null -eq $planResult.plan.PSObject.Properties['temporaryDirectory']) -Message ('Artifact planning returned an owned directory: {0}' -f $case.kind)
            Assert-Equal -Expected ($before -join '|') -Actual ($after -join '|') -Message ('Artifact planning created a temporary directory: {0}' -f $case.kind)
            $fileIndex = [int]$planResult.plan.artifact.fileArgumentIndex
            Assert-True -Condition ($null -eq $planResult.plan.arguments[$fileIndex]) -Message ('Artifact path was materialized during planning: {0}' -f $case.kind)
        }
    }

    Invoke-Test -Name 'Artifact cleanup failure preserves the completed child attempt' -Body {
        $workerPath = Join-Path $tempRoot 'mmx.ps1'
        [System.IO.File]::WriteAllText(
            $workerPath,
            '[Console]::Write(''WORKER_COMPLETED'')',
            (New-Object System.Text.UTF8Encoding($false))
        )
        $plan = [pscustomobject]@{
            filePath = $workerPath
            arguments = @('--messages-file', $null)
            workingDirectory = $tempRoot
            standardInputText = $null
            environmentOverlay = [pscustomobject]@{}
            allowBatchWorker = $false
            artifact = [pscustomobject]@{
                kind = 'minimax-messages'
                promptText = 'cleanup failure probe'
                fileArgumentIndex = 1
                fileArgumentFormat = '{0}'
                directoryArgumentIndex = $null
            }
        }
        $originalCleanup = (Get-Item Function:\Remove-AiwTemporaryDirectory).ScriptBlock
        $script:cleanupProbePath = $null
        Set-Item -Path Function:\Remove-AiwTemporaryDirectory -Value {
            param([Parameter(Mandatory)][string]$Path)
            $script:cleanupProbePath = $Path
            throw 'Injected cleanup failure.'
        }
        try {
            $result = Invoke-AiwPlannedWorker `
                -Plan $plan `
                -TimeoutSeconds 10 `
                -TimeoutMilliseconds 10000
        } finally {
            Set-Item `
                -Path Function:\Remove-AiwTemporaryDirectory `
                -Value $originalCleanup
        }
        try {
            Assert-Equal -Expected 126 -Actual $result.ExitCode -Message 'Cleanup failure public exit code changed'
            Assert-Equal -Expected 0 -Actual $result.ChildExitCodeOverride -Message 'Cleanup failure lost the child exit code'
            Assert-Equal -Expected 'wrapper_error' -Actual (Get-WorkerFailureKind -Result $result) -Message 'Cleanup failure kind changed'
            Assert-Equal -Expected 'cleanup' -Actual $result.FailurePhaseOverride -Message 'Cleanup failure phase changed'
            Assert-True -Condition $result.CleanupFailed -Message 'Cleanup failure flag was not set'
            Assert-Equal -Expected 'WORKER_COMPLETED' -Actual $result.StandardOutput -Message 'Cleanup failure lost completed worker output'
            Assert-True -Condition (Test-Path -LiteralPath $script:cleanupProbePath -PathType Container) -Message 'Cleanup failure fixture did not preserve the owned directory'
            Assert-True -Condition (Get-PublicWorkerDiagnostics -Result $result).Contains('cleanup failed') -Message 'Cleanup failure diagnostic was not explicit'
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($script:cleanupProbePath) -and
                (Test-Path -LiteralPath $script:cleanupProbePath -PathType Container)) {
                & $originalCleanup -Path $script:cleanupProbePath
            }
            $script:cleanupProbePath = $null
        }
    }

    Invoke-Test -Name 'V2 run rejects legacy model override flags before planning a worker' -Body {
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        foreach ($flag in @('-Model', '-GoogleModel', '-AgentModel')) {
            $arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-File', $launcherPath,
                'run',
                '-Worker', 'fixture',
                '-Prompt', 'model override must fail before execution',
                '-Mode', 'read',
                '-WorkingDirectory', $tempRoot,
                '-OutputSchema', '2',
                '-Json',
                $flag, 'unreviewed-model'
            )
            $output = & $hostPath @arguments
            $exitCode = $LASTEXITCODE
            $result = (@($output) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 2 -Actual $exitCode -Message ('V2 model override exit code changed: {0}' -f $flag)
            Assert-Equal -Expected 'invalid_request' -Actual $result.failureKind -Message ('V2 model override failure kind changed: {0}' -f $flag)
            Assert-Equal -Expected 'MODEL_OVERRIDE_FORBIDDEN' -Actual $result.error.code -Message ('V2 model override error code changed: {0}' -f $flag)
            Assert-True -Condition (-not $result.outputLimitExceeded) -Message ('V2 model override output-limit default changed: {0}' -f $flag)
            Assert-True -Condition (-not $result.containmentApplied) -Message ('V2 model override containment default changed: {0}' -f $flag)
            Assert-True -Condition (-not $result.treeTerminationConfirmed) -Message ('V2 model override tree default changed: {0}' -f $flag)
        }
    }

    Invoke-Test -Name 'V2 run preflight failures keep one complete stable envelope' -Body {
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $missingDirectory = Join-Path $tempRoot 'missing-working-directory'
        $missingPrompt = Join-Path $tempRoot 'missing-work-order.md'
        $invalidConfig = Join-Path $tempRoot 'invalid-run-config.json'
        [System.IO.File]::WriteAllText($invalidConfig, '{ invalid json')
        $cases = @(
            [pscustomobject]@{
                name = 'working-directory'
                expectedCode = 'WORKDIR_INVALID'
                arguments = @(
                    '-Worker', 'fixture',
                    '-Prompt', 'must not launch',
                    '-WorkingDirectory', $missingDirectory
                )
            },
            [pscustomobject]@{
                name = 'prompt'
                expectedCode = 'PROMPT_INVALID'
                arguments = @(
                    '-Worker', 'fixture',
                    '-PromptFile', $missingPrompt,
                    '-WorkingDirectory', $tempRoot
                )
            },
            [pscustomobject]@{
                name = 'prompt-limit-policy'
                expectedCode = 'PROMPT_INVALID'
                arguments = @(
                    '-Worker', 'fixture',
                    '-Prompt', 'must not launch',
                    '-WorkingDirectory', $tempRoot,
                    '-MaxPromptBytes', '1048577'
                )
            },
            [pscustomobject]@{
                name = 'configuration'
                expectedCode = 'CONFIG_INVALID'
                arguments = @(
                    '-Worker', 'fixture',
                    '-Prompt', 'must not launch',
                    '-WorkingDirectory', $tempRoot,
                    '-ConfigPath', $invalidConfig
                )
            }
        )

        foreach ($case in $cases) {
            $arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-File', $launcherPath,
                'run',
                '-Mode', 'read',
                '-OutputSchema', '2',
                '-Json'
            ) + $case.arguments
            $output = & $hostPath @arguments
            $exitCode = $LASTEXITCODE
            $result = (@($output) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 2 -Actual $exitCode -Message ('V2 preflight exit code changed: {0}' -f $case.name)
            Assert-Equal -Expected 2 -Actual $result.schemaVersion -Message ('V2 preflight schema changed: {0}' -f $case.name)
            Assert-Equal -Expected $script:ExpectedProductVersion -Actual $result.productVersion -Message ('V2 preflight product version changed: {0}' -f $case.name)
            Assert-Equal -Expected 'run' -Actual $result.command -Message ('V2 preflight command changed: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedCode -Actual $result.error.code -Message ('V2 preflight code changed: {0}' -f $case.name)
            Assert-Equal -Expected 'preflight' -Actual $result.error.phase -Message ('V2 preflight phase changed: {0}' -f $case.name)
            Assert-True -Condition ($null -ne $result.request) -Message ('V2 preflight request is missing: {0}' -f $case.name)
            Assert-True -Condition ($null -eq $result.selection) -Message ('V2 preflight unexpectedly selected a worker: {0}' -f $case.name)
            Assert-True -Condition (-not $result.timedOut) -Message ('V2 preflight timeout default changed: {0}' -f $case.name)
            Assert-True -Condition (-not $result.readTimedOut) -Message ('V2 preflight read-timeout default changed: {0}' -f $case.name)
            Assert-True -Condition (-not $result.outputLimitExceeded) -Message ('V2 preflight output-limit default changed: {0}' -f $case.name)
            Assert-True -Condition (-not $result.containmentApplied) -Message ('V2 preflight containment default changed: {0}' -f $case.name)
            Assert-True -Condition (-not $result.treeTerminationConfirmed) -Message ('V2 preflight tree default changed: {0}' -f $case.name)
            Assert-Equal -Expected 0 -Actual @($result.attempts).Count -Message ('V2 preflight started an attempt: {0}' -f $case.name)
            Assert-Equal -Expected '' -Actual $result.output -Message ('V2 preflight output default changed: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate returns stable structured errors for parse encoding size and schema failures' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'invalid-json'
                expectedCode = 'JSON_INVALID'
                write = {
                    param($path)
                    [System.IO.File]::WriteAllText($path, '{ invalid json')
                }
            },
            [pscustomobject]@{
                name = 'invalid-utf8'
                expectedCode = 'ENCODING_INVALID'
                write = {
                    param($path)
                    [System.IO.File]::WriteAllBytes($path, [byte[]](0xFF, 0xFE, 0xFA))
                }
            },
            [pscustomobject]@{
                name = 'oversized'
                expectedCode = 'CONFIG_LIMIT_EXCEEDED'
                write = {
                    param($path)
                    [System.IO.File]::WriteAllText($path, (' ' * 1048577))
                }
            },
            [pscustomobject]@{
                name = 'schema'
                expectedCode = 'SCHEMA_VERSION_UNSUPPORTED'
                write = {
                    param($path)
                    Write-TestJson -Path $path -Value ([ordered]@{
                        schemaVersion = 3
                        workers = [ordered]@{}
                        profiles = [ordered]@{}
                        routes = [ordered]@{}
                    })
                }
            }
        )

        foreach ($case in $cases) {
            $configPath = Join-Path $tempRoot ('invalid-config-{0}.json' -f $case.name)
            & $case.write $configPath
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Invalid config returned the wrong exit code: {0}' -f $case.name)
            Assert-True -Condition (-not $validation.result.ok) -Message ('Invalid config was accepted: {0}' -f $case.name)
            Assert-Equal -Expected 'config_invalid' -Actual $validation.result.failureKind -Message ('Invalid config failure kind changed: {0}' -f $case.name)
            Assert-Equal -Expected 'CONFIG_INVALID' -Actual $validation.result.error.code -Message ('Invalid config envelope code changed: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedCode -Actual $validation.result.errors[0].code -Message ('Invalid config detail code changed: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate accepts a UTF-8 BOM document on Windows PowerShell' -Body {
        $configPath = Join-Path $tempRoot 'utf8-bom-config-v2.json'
        $config = New-RoutingFixtureConfig
        [System.IO.File]::WriteAllText(
            $configPath,
            ($config | ConvertTo-Json -Depth 20),
            (New-Object System.Text.UTF8Encoding($true))
        )

        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'UTF-8 BOM config returned a non-zero exit code'
        Assert-True -Condition $validation.result.ok -Message 'UTF-8 BOM config was rejected'
    }

    Invoke-Test -Name 'Config validate caps semantic errors with stable truncation metadata' -Body {
        $configPath = Join-Path $tempRoot 'many-semantic-errors-v2.json'
        $config = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{}
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        for ($index = 1; $index -le 70; $index++) {
            $config['unknown' + $index] = 'ignored'
        }
        Write-TestJson -Path $configPath -Value $config

        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 2 -Actual $validation.exitCode -Message 'Many-error validation returned the wrong exit code'
        Assert-Equal -Expected 64 -Actual @($validation.result.errors).Count -Message 'Semantic error cap changed'
        Assert-Equal -Expected 70 -Actual $validation.result.errorCount -Message 'Semantic error count changed'
        Assert-True -Condition $validation.result.errorsTruncated -Message 'Semantic error truncation was not reported'
        Assert-True -Condition $validation.result.warnings[0].Contains('64') -Message 'Semantic error truncation warning changed'
        Assert-Equal -Expected '$.unknown1' -Actual $validation.result.errors[0].path -Message 'Semantic error ordering changed'
    }

    Invoke-Test -Name 'Config validate accepts legacy schema v1 for in-memory migration compatibility' -Body {
        $configPath = Join-Path $tempRoot 'legacy-v1-validation.json'
        $legacyConfig = [ordered]@{
            schemaVersion = 1
            workers = [ordered]@{
                ark = [ordered]@{
                    path = $null
                    model = 'glm-5.2'
                    configPath = '%USERPROFILE%\.claude\settings.json'
                }
            }
        }
        Write-TestJson -Path $configPath -Value $legacyConfig
        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Legacy schema v1 validation failed'
        Assert-True -Condition $validation.result.ok -Message 'Legacy schema v1 was rejected'
        Assert-Equal -Expected 1 -Actual $validation.result.configSchemaVersion -Message 'Legacy schema version was not reported'
    }

    Invoke-Test -Name 'Config migrate writes a credential-free v2 destination without changing schema v1 source' -Body {
        $sourcePath = Join-Path $tempRoot 'legacy-v1-migration-source.json'
        $destinationPath = Join-Path $tempRoot 'legacy-v1-migration-destination.json'
        $secretSentinel = 'MIGRATION_SECRET_SENTINEL'
        $legacyConfig = [ordered]@{
            schemaVersion = 1
            workers = [ordered]@{
                ark = [ordered]@{
                    path = $null
                    model = 'glm-5.2'
                    configPath = '%USERPROFILE%\.claude\settings.json'
                }
                agent = [ordered]@{
                    path = $null
                    model = 'ark-code-latest'
                    configDirectory = '%USERPROFILE%\.claude-agent-plan'
                }
                google = [ordered]@{
                    path = $null
                    model = 'gemini-3.6-flash-high'
                    configDirectory = '%USERPROFILE%\.gemini\antigravity-cli'
                }
                minimax = [ordered]@{
                    path = $null
                    model = 'MiniMax-M3'
                    configPath = '%USERPROFILE%\.mmx\config.json'
                    baseUrl = 'https://api.minimax.io'
                    apiKey = $secretSentinel
                }
            }
        }
        Write-TestJson -Path $sourcePath -Value $legacyConfig
        $sourceBytesBefore = [System.IO.File]::ReadAllBytes($sourcePath)
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $migrationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action migrate `
            -ConfigPath $sourcePath `
            -Destination $destinationPath `
            -Json
        $migrationExitCode = $LASTEXITCODE
        $migration = (@($migrationOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $migrationExitCode -Message 'Migration returned a non-zero exit code'
        Assert-True -Condition $migration.ok -Message 'Migration did not succeed'
        Assert-Equal -Expected $script:ExpectedProductVersion -Actual $migration.productVersion -Message 'Migration product version changed'
        Assert-Equal -Expected 'migrate' -Actual $migration.action -Message 'Migration action changed'
        Assert-Equal -Expected $destinationPath -Actual $migration.destinationPath -Message 'Migration destination changed'
        Assert-True -Condition (Test-Path -LiteralPath $destinationPath -PathType Leaf) -Message 'Migration did not create its destination'
        Assert-Equal `
            -Expected ([Convert]::ToBase64String($sourceBytesBefore)) `
            -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sourcePath))) `
            -Message 'Migration changed its source file'

        $migratedText = Get-Content -Raw -LiteralPath $destinationPath
        $migrated = $migratedText | ConvertFrom-Json
        Assert-Equal -Expected 2 -Actual $migrated.schemaVersion -Message 'Migration output schema changed'
        Assert-Equal -Expected 'claude-code/v1' -Actual $migrated.workers.'legacy-ark'.adapter -Message 'Ark adapter migration changed'
        Assert-Equal -Expected '%USERPROFILE%\.claude-agent-plan' -Actual $migrated.workers.'legacy-agent'.settings.configDirectory -Message 'Agent profile migration changed'
        Assert-Equal -Expected 'antigravity/v1' -Actual $migrated.workers.'legacy-google'.adapter -Message 'Google adapter migration changed'
        Assert-Equal -Expected 'global' -Actual $migrated.workers.'legacy-minimax'.settings.region -Message 'MiniMax region migration changed'
        Assert-True -Condition (-not $migratedText.Contains($secretSentinel)) -Message 'Migration copied a credential-like value'
        Assert-True -Condition (-not $migratedText.Contains('apiKey')) -Message 'Migration copied a credential field'
        Assert-True -Condition (-not $migratedText.Contains('baseUrl')) -Message 'Migration copied an arbitrary endpoint'

        $repeatOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action migrate `
            -ConfigPath $sourcePath `
            -Destination $destinationPath `
            -Json
        $repeatExitCode = $LASTEXITCODE
        $repeat = (@($repeatOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal -Expected 2 -Actual $repeatExitCode -Message 'Migration overwrote an existing destination'
        Assert-Equal -Expected 'DESTINATION_EXISTS' -Actual $repeat.errors[0].code -Message 'Existing destination failure code changed'
    }

    Invoke-Test -Name 'Sparse schema v1 migration preserves the legacy Agent Plan profile default' -Body {
        $sourcePath = Join-Path $tempRoot 'sparse-v1-agent-source.json'
        $destinationPath = Join-Path $tempRoot 'sparse-v1-agent-destination.json'
        Write-TestJson -Path $sourcePath -Value ([ordered]@{
            schemaVersion = 1
            workers = [ordered]@{
                agent = [ordered]@{
                    path = $null
                    model = 'ark-code-latest'
                }
            }
        })
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $migrationOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            config `
            -Action migrate `
            -ConfigPath $sourcePath `
            -Destination $destinationPath `
            -Json
        $migrationExitCode = $LASTEXITCODE
        $migration = (@($migrationOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        $migrated = (Get-Content -Raw -LiteralPath $destinationPath) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $migrationExitCode -Message 'Sparse migration returned a non-zero exit code'
        Assert-True -Condition $migration.ok -Message 'Sparse migration failed'
        Assert-Equal `
            -Expected '%USERPROFILE%\.claude-agent-plan' `
            -Actual $migrated.workers.'legacy-agent'.settings.configDirectory `
            -Message 'Sparse migration lost the legacy Agent Plan profile default'
    }

    Invoke-Test -Name 'V2 doctor fails only when an enabled configured worker set is unusable' -Body {
        $configPath = Join-Path $tempRoot 'unavailable-doctor-v2.json'
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = Join-Path $tempRoot 'missing-doctor-worker\claude.ps1'
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $doctorOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            doctor `
            -OutputSchema 2 `
            -ConfigPath $configPath `
            -Json
        $doctorExitCode = $LASTEXITCODE
        $doctorText = @($doctorOutput) -join [Environment]::NewLine
        $doctor = $doctorText | ConvertFrom-Json

        Assert-Equal -Expected 1 -Actual $doctorExitCode -Message 'Unusable v2 doctor returned the wrong exit code'
        Assert-True -Condition (-not $doctor.ok) -Message 'Unusable v2 doctor succeeded'
        Assert-Equal -Expected 'CONFIGURED_WORKERS_UNAVAILABLE' -Actual $doctor.error.code -Message 'Unusable v2 doctor error changed'
        Assert-True -Condition ($doctorText -match '"warnings"\s*:\s*\[') -Message 'V2 doctor warnings did not serialize as an array'
        Assert-True -Condition (@($doctor.warnings).Count -gt 0) -Message 'Unusable v2 doctor did not explain its warning'
        Assert-Equal -Expected 1 -Actual @($doctor.profiles).Count -Message 'V2 doctor profile inventory changed'
        Assert-Equal -Expected 1 -Actual @($doctor.routes).Count -Message 'V2 doctor route inventory changed'
    }

    Invoke-Test -Name 'V2 doctor and run reject a missing trusted native profile before worker launch' -Body {
        $workerPath = Join-Path $tempRoot 'claude.ps1'
        $markerPath = Join-Path $tempRoot 'missing-profile-worker-started.marker'
        $missingProfileDirectory = Join-Path $tempRoot 'missing-native-profile'
        $configPath = Join-Path $tempRoot 'missing-profile-v2.json'
        $promptPath = Join-Path $tempRoot 'missing-profile-prompt.md'
        [System.IO.File]::WriteAllText(
            $workerPath,
            ('[System.IO.File]::WriteAllText(''{0}'', ''started'')' -f $markerPath.Replace("'", "''")),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'profile preflight task')
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $workerPath
        $config.workers.fixture.settings = [ordered]@{ configDirectory = $missingProfileDirectory }
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable

        $doctorOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            doctor `
            -OutputSchema 2 `
            -ConfigPath $configPath `
            -Json
        $doctorExitCode = $LASTEXITCODE
        $doctor = (@($doctorOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal -Expected 1 -Actual $doctorExitCode -Message 'Missing-profile doctor returned the wrong exit code'
        Assert-Equal -Expected 'profile_unavailable' -Actual $doctor.workers[0].availability -Message 'Missing-profile doctor availability changed'
        Assert-True -Condition $doctor.workers[0].executableAvailable -Message 'Missing-profile doctor lost executable evidence'
        Assert-True -Condition (-not $doctor.workers[0].profileDirectoryExists) -Message 'Missing-profile doctor accepted a missing profile directory'

        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker fixture `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal -Expected 2 -Actual $runExitCode -Message 'Missing-profile run returned the wrong exit code'
        Assert-Equal -Expected 'profile_directory_invalid' -Actual $run.failureKind -Message 'Missing-profile run failure kind changed'
        Assert-Equal -Expected 'PROFILE_DIRECTORY_INVALID' -Actual $run.error.code -Message 'Missing-profile run error code changed'
        Assert-True -Condition (-not (Test-Path -LiteralPath $markerPath)) -Message 'Missing-profile worker was started'
    }

    Invoke-Test -Name 'Config validate rejects raw duplicate properties before ConvertFrom-Json' -Body {
        $workerJson = '{"adapter":"claude-code/v1","enabled":true,"path":null,"model":"fixture-model","capabilities":["text.reason"],"settings":{}}'
        $cases = @(
            [pscustomobject]@{
                name = 'exact'
                text = '{"schemaVersion":2,"defaultRoute":null,"defaultProfile":null,"workers":{"same":' + $workerJson + ',"same":' + $workerJson + '},"profiles":{},"routes":{}}'
                expectedPath = '$.workers.same'
            },
            [pscustomobject]@{
                name = 'case-insensitive'
                text = '{"schemaVersion":2,"defaultRoute":null,"defaultProfile":null,"workers":{"same":' + $workerJson + ',"Same":' + $workerJson + '},"profiles":{},"routes":{}}'
                expectedPath = '$.workers.same'
            },
            [pscustomobject]@{
                name = 'unicode-escape'
                text = '{"schemaVersion":2,"defaultRoute":null,"defaultProfile":null,"workers":{"same":' + $workerJson + ',"\u0073ame":' + $workerJson + '},"profiles":{},"routes":{}}'
                expectedPath = '$.workers.same'
            }
        )

        foreach ($case in $cases) {
            $configPath = Join-Path $tempRoot ('duplicate-{0}.json' -f $case.name)
            [System.IO.File]::WriteAllText(
                $configPath,
                $case.text,
                (New-Object System.Text.UTF8Encoding($false))
            )
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Duplicate property returned the wrong exit code: {0}' -f $case.name)
            Assert-Equal -Expected 'FIELD_DUPLICATE' -Actual $validation.result.errors[0].code -Message ('Duplicate property returned the wrong code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedPath -Actual $validation.result.errors[0].path -Message ('Duplicate property returned the wrong path: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Raw duplicate detection redacts secret-like property names and values' -Body {
        $configPath = Join-Path $tempRoot 'duplicate-secret.json'
        $secretSentinel = 'DUPLICATE_SECRET_SENTINEL'
        $rawConfig = '{"schemaVersion":2,"defaultRoute":null,"defaultProfile":null,"workers":{"fixture":{"adapter":"claude-code/v1","enabled":true,"path":null,"model":"fixture-model","capabilities":["text.reason"],"settings":{"token":"' + $secretSentinel + '","TOKEN":"second-secret"}}},"profiles":{},"routes":{}}'
        [System.IO.File]::WriteAllText(
            $configPath,
            $rawConfig,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 2 -Actual $validation.exitCode -Message 'Secret duplicate returned the wrong exit code'
        Assert-Equal -Expected 'FIELD_DUPLICATE' -Actual $validation.result.errors[0].code -Message 'Secret duplicate returned the wrong code'
        Assert-Equal -Expected '$.workers.fixture.settings.<redacted>' -Actual $validation.result.errors[0].path -Message 'Secret duplicate path was not redacted'
        Assert-True -Condition (-not $validation.text.Contains('token')) -Message 'Secret duplicate property name leaked'
        Assert-True -Condition (-not $validation.text.Contains($secretSentinel)) -Message 'Secret duplicate property value leaked'
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

    Invoke-Test -Name 'Config validate rejects an existing unsafe executable before any worker launch' -Body {
        $unsafePath = Join-Path $tempRoot 'evil.exe'
        $configPath = Join-Path $tempRoot 'unsafe-launcher-v2.json'
        [System.IO.File]::WriteAllText($unsafePath, 'not a trusted worker')
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $unsafePath
        Write-TestJson -Path $configPath -Value $config

        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 2 -Actual $validation.exitCode -Message 'Unsafe executable validation returned the wrong exit code'
        Assert-Equal -Expected 'LAUNCHER_UNSAFE' -Actual $validation.result.errors[0].code -Message 'Unsafe executable validation code changed'
        Assert-Equal -Expected '$.workers.fixture.path' -Actual $validation.result.errors[0].path -Message 'Unsafe executable validation path changed'
        Assert-True -Condition (-not $validation.text.Contains($unsafePath)) -Message 'Unsafe executable path leaked into validation output'
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

    Invoke-Test -Name 'Config validate prevents adapter capability escalation' -Body {
        $configPath = Join-Path $tempRoot 'capability-escalation-v2.json'
        $capabilityConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                stateless = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $null
                    model = 'fixture-model'
                    capabilities = @('text.reason', 'workspace.read')
                    settings = [ordered]@{ region = 'cn' }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $capabilityConfig -Depth 10),
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

        Assert-Equal -Expected 2 -Actual $validationExitCode -Message 'Capability escalation returned the wrong exit code'
        Assert-Equal -Expected 'CAPABILITY_NOT_SUPPORTED' -Actual $validation.errors[0].code -Message 'Capability escalation error code changed'
        Assert-Equal -Expected '$.workers.stateless.capabilities[1]' -Actual $validation.errors[0].path -Message 'Capability escalation path changed'
    }

    Invoke-Test -Name 'Config validate enforces reviewed adapter-specific settings' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'minimax-base-url'
                adapter = 'minimax-cli/v1'
                settings = [ordered]@{ region = 'cn'; baseUrl = 'https://attacker.invalid' }
                expectedCode = 'FIELD_UNKNOWN'
                expectedPath = '$.workers.fixture.settings.baseUrl'
            },
            [pscustomobject]@{
                name = 'minimax-region-enum'
                adapter = 'minimax-cli/v1'
                settings = [ordered]@{ region = 'unreviewed' }
                expectedCode = 'FIELD_VALUE_INVALID'
                expectedPath = '$.workers.fixture.settings.region'
            },
            [pscustomobject]@{
                name = 'minimax-settings-type'
                adapter = 'minimax-cli/v1'
                settings = 'cn'
                expectedCode = 'FIELD_TYPE_INVALID'
                expectedPath = '$.workers.fixture.settings'
            },
            [pscustomobject]@{
                name = 'antigravity-config-directory'
                adapter = 'antigravity/v1'
                settings = [ordered]@{ configDirectory = '%USERPROFILE%\.unsupported' }
                expectedCode = 'FIELD_UNKNOWN'
                expectedPath = '$.workers.fixture.settings.configDirectory'
            }
        )

        foreach ($case in $cases) {
            $configPath = Join-Path $tempRoot ('settings-{0}.json' -f $case.name)
            $settingsConfig = [ordered]@{
                schemaVersion = 2
                defaultRoute = $null
                defaultProfile = $null
                workers = [ordered]@{
                    fixture = [ordered]@{
                        adapter = $case.adapter
                        enabled = $true
                        path = $null
                        model = 'fixture-model'
                        capabilities = @('text.reason')
                        settings = $case.settings
                    }
                }
                profiles = [ordered]@{}
                routes = [ordered]@{}
            }
            [System.IO.File]::WriteAllText(
                $configPath,
                (ConvertTo-Json -InputObject $settingsConfig -Depth 10),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Adapter settings case returned the wrong exit code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedCode -Actual $validation.result.errors[0].code -Message ('Adapter settings case returned the wrong error: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedPath -Actual $validation.result.errors[0].path -Message ('Adapter settings case returned the wrong path: {0}' -f $case.name)
            Assert-True -Condition (-not $validation.text.Contains('attacker.invalid')) -Message ('Adapter settings case leaked a rejected value: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate accepts MiniMax reviewed region and config directory' -Body {
        $configPath = Join-Path $tempRoot 'settings-minimax-reviewed.json'
        $settingsConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                fixture = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $null
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{
                        region = 'global'
                        configDirectory = '%USERPROFILE%\.mmx'
                    }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $settingsConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $validation = Invoke-PublicConfigValidation -Path $configPath

        Assert-Equal -Expected 0 -Actual $validation.exitCode -Message 'Reviewed MiniMax settings were rejected'
        Assert-True -Condition $validation.result.ok -Message 'Reviewed MiniMax settings validation failed'
    }

    Invoke-Test -Name 'Config validate rejects unsafe MiniMax model values before launch' -Body {
        $models = @('bad&model', ('m' * 129))
        foreach ($model in $models) {
            $configPath = Join-Path $tempRoot ('unsafe-minimax-model-{0}.json' -f $model.Length)
            $modelConfig = [ordered]@{
                schemaVersion = 2
                defaultRoute = $null
                defaultProfile = $null
                workers = [ordered]@{
                    fixture = [ordered]@{
                        adapter = 'minimax-cli/v1'
                        enabled = $true
                        path = $null
                        model = $model
                        capabilities = @('text.reason')
                        settings = [ordered]@{ region = 'cn' }
                    }
                }
                profiles = [ordered]@{}
                routes = [ordered]@{}
            }
            [System.IO.File]::WriteAllText(
                $configPath,
                (ConvertTo-Json -InputObject $modelConfig -Depth 10),
                (New-Object System.Text.UTF8Encoding($false))
            )
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message 'Unsafe MiniMax model returned the wrong exit code'
            Assert-Equal -Expected 'MODEL_INVALID' -Actual $validation.result.errors[0].code -Message 'Unsafe MiniMax model error code changed'
            Assert-Equal -Expected '$.workers.fixture.model' -Actual $validation.result.errors[0].path -Message 'Unsafe MiniMax model path changed'
            Assert-True -Condition (-not $validation.text.Contains($model)) -Message 'Unsafe MiniMax model value leaked into validation output'
        }
    }

    Invoke-Test -Name 'Config validate rejects scalar values where typed fields require booleans strings or arrays' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'enabled'
                mutate = { param($config) $config.workers.fixture.enabled = 1 }
                expectedPath = '$.workers.fixture.enabled'
            },
            [pscustomobject]@{
                name = 'path'
                mutate = { param($config) $config.workers.fixture.path = 7 }
                expectedPath = '$.workers.fixture.path'
            },
            [pscustomobject]@{
                name = 'model'
                mutate = { param($config) $config.workers.fixture.model = 7 }
                expectedPath = '$.workers.fixture.model'
            },
            [pscustomobject]@{
                name = 'capabilities'
                mutate = { param($config) $config.workers.fixture.capabilities = 'text.reason' }
                expectedPath = '$.workers.fixture.capabilities'
            },
            [pscustomobject]@{
                name = 'profile-workers'
                mutate = { param($config) $config.profiles.standard.workers = 'fixture' }
                expectedPath = '$.profiles.standard.workers'
            },
            [pscustomobject]@{
                name = 'route-capabilities'
                mutate = { param($config) $config.routes.review.requiredCapabilities = 'text.reason' }
                expectedPath = '$.routes.review.requiredCapabilities'
            },
            [pscustomobject]@{
                name = 'route-modes'
                mutate = { param($config) $config.routes.review.allowedModes = 'read' }
                expectedPath = '$.routes.review.allowedModes'
            }
        )

        foreach ($case in $cases) {
            $config = New-RoutingFixtureConfig
            & $case.mutate $config
            $configPath = Join-Path $tempRoot ('typed-field-{0}.json' -f $case.name)
            Write-TestJson -Path $configPath -Value $config
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Typed field case returned the wrong exit code: {0}' -f $case.name)
            Assert-Equal -Expected 'FIELD_TYPE_INVALID' -Actual $validation.result.errors[0].code -Message ('Typed field case returned the wrong code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedPath -Actual $validation.result.errors[0].path -Message ('Typed field case returned the wrong path: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate enforces bounded fallback policy shape and failure kinds' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'fallback-type'
                value = 'process_exit'
                expectedCode = 'FIELD_TYPE_INVALID'
                expectedPath = '$.profiles.standard.fallback'
            },
            [pscustomobject]@{
                name = 'attempts-type'
                value = [ordered]@{ maxAttempts = '2'; on = @('process_exit') }
                expectedCode = 'FIELD_TYPE_INVALID'
                expectedPath = '$.profiles.standard.fallback.maxAttempts'
            },
            [pscustomobject]@{
                name = 'attempts-range'
                value = [ordered]@{ maxAttempts = 0; on = @('process_exit') }
                expectedCode = 'FIELD_VALUE_INVALID'
                expectedPath = '$.profiles.standard.fallback.maxAttempts'
            },
            [pscustomobject]@{
                name = 'on-type'
                value = [ordered]@{ maxAttempts = 2; on = 'process_exit' }
                expectedCode = 'FIELD_TYPE_INVALID'
                expectedPath = '$.profiles.standard.fallback.on'
            },
            [pscustomobject]@{
                name = 'forbidden-kind'
                value = [ordered]@{ maxAttempts = 2; on = @('permission_denied') }
                expectedCode = 'FALLBACK_KIND_FORBIDDEN'
                expectedPath = '$.profiles.standard.fallback.on[0]'
            }
        )

        foreach ($case in $cases) {
            $config = New-RoutingFixtureConfig
            $config.profiles.standard.fallback = $case.value
            $configPath = Join-Path $tempRoot ('fallback-{0}.json' -f $case.name)
            Write-TestJson -Path $configPath -Value $config
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Fallback case returned the wrong exit code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedCode -Actual $validation.result.errors[0].code -Message ('Fallback case returned the wrong code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedPath -Actual $validation.result.errors[0].path -Message ('Fallback case returned the wrong path: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate enforces exact default and reference resolution' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'default-route-missing'
                mutate = { param($config) $config.defaultRoute = 'missing' }
                expectedCode = 'ROUTE_NOT_FOUND'
                expectedPath = '$.defaultRoute'
            },
            [pscustomobject]@{
                name = 'default-profile-missing'
                mutate = { param($config) $config.defaultProfile = 'missing' }
                expectedCode = 'PROFILE_NOT_FOUND'
                expectedPath = '$.defaultProfile'
            },
            [pscustomobject]@{
                name = 'default-conflict'
                mutate = { param($config) $config.defaultRoute = 'review'; $config.defaultProfile = 'standard' }
                expectedCode = 'DEFAULT_SELECTION_CONFLICT'
                expectedPath = '$'
            },
            [pscustomobject]@{
                name = 'default-type'
                mutate = { param($config) $config.defaultRoute = 7 }
                expectedCode = 'FIELD_TYPE_INVALID'
                expectedPath = '$.defaultRoute'
            },
            [pscustomobject]@{
                name = 'profile-case'
                mutate = { param($config) $config.routes.review.profile = 'STANDARD' }
                expectedCode = 'PROFILE_NOT_FOUND'
                expectedPath = '$.routes.review.profile'
            },
            [pscustomobject]@{
                name = 'worker-case'
                mutate = { param($config) $config.profiles.standard.workers = @('FIXTURE') }
                expectedCode = 'WORKER_NOT_FOUND'
                expectedPath = '$.profiles.standard.workers[0]'
            },
            [pscustomobject]@{
                name = 'worker-duplicate'
                mutate = { param($config) $config.profiles.standard.workers = @('fixture', 'fixture') }
                expectedCode = 'FIELD_VALUE_INVALID'
                expectedPath = '$.profiles.standard.workers[1]'
            }
        )

        foreach ($case in $cases) {
            $config = New-RoutingFixtureConfig
            & $case.mutate $config
            $configPath = Join-Path $tempRoot ('reference-{0}.json' -f $case.name)
            Write-TestJson -Path $configPath -Value $config
            $validation = Invoke-PublicConfigValidation -Path $configPath

            Assert-Equal -Expected 2 -Actual $validation.exitCode -Message ('Reference case returned the wrong exit code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedCode -Actual $validation.result.errors[0].code -Message ('Reference case returned the wrong code: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedPath -Actual $validation.result.errors[0].path -Message ('Reference case returned the wrong path: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Config validate prevents routes from defaulting to write' -Body {
        $configPath = Join-Path $tempRoot 'route-default-write-v2.json'
        $routeConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = 'reason'
            defaultProfile = $null
            workers = [ordered]@{
                stateless = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $null
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{ region = 'cn' }
                }
            }
            profiles = [ordered]@{
                reasoning = [ordered]@{
                    workers = @('stateless')
                    fallback = [ordered]@{ maxAttempts = 1; on = @() }
                }
            }
            routes = [ordered]@{
                reason = [ordered]@{
                    profile = 'reasoning'
                    requiredCapabilities = @('text.reason')
                    defaultMode = 'write'
                    allowedModes = @('read', 'write')
                }
            }
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $routeConfig -Depth 10),
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

        Assert-Equal -Expected 2 -Actual $validationExitCode -Message 'Write-default route returned the wrong exit code'
        Assert-Equal -Expected 'ROUTE_DEFAULT_WRITE_FORBIDDEN' -Actual $validation.errors[0].code -Message 'Write-default route error code changed'
        Assert-Equal -Expected '$.routes.reason.defaultMode' -Actual $validation.errors[0].path -Message 'Write-default route path changed'
    }

    Invoke-Test -Name 'Public V2 results withhold CRLF-fragmented worker diagnostics that echo a work order' -Body {
        $fixtureDirectory = Join-Path $tempRoot 'privacy-fixture'
        $workerPath = Join-Path $fixtureDirectory 'claude.ps1'
        $configPath = Join-Path $tempRoot 'privacy-run-v2.json'
        $promptPath = Join-Path $tempRoot 'privacy-run-prompt.md'
        $workOrder = "line one unique-privacy-sentinel`nline two unique-privacy-sentinel"
        [void](New-Item -ItemType Directory -Path $fixtureDirectory)
        $fixtureScript = @'
$diagnostic = [Console]::In.ReadToEnd().Replace("`n", "`r`n")
for ($index = 0; $index -lt $diagnostic.Length; $index += 3) {
    $count = [Math]::Min(3, $diagnostic.Length - $index)
    [Console]::Error.Write($diagnostic.Substring($index, $count))
}
exit 9
'@
        [System.IO.File]::WriteAllText($workerPath, $fixtureScript, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($promptPath, $workOrder, (New-Object System.Text.UTF8Encoding($false)))
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $workerPath
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $jsonOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker fixture `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $jsonExitCode = $LASTEXITCODE
        $jsonText = @($jsonOutput) -join [Environment]::NewLine
        $jsonResult = $jsonText | ConvertFrom-Json

        Assert-Equal -Expected 1 -Actual $jsonExitCode -Message 'Privacy fixture JSON run returned the wrong exit code'
        Assert-Equal -Expected 'process_exit' -Actual $jsonResult.failureKind -Message 'Privacy fixture failure kind changed'
        Assert-True -Condition (-not $jsonText.Contains('unique-privacy-sentinel')) -Message 'Privacy fixture leaked its work order into JSON output'
        Assert-True -Condition $jsonResult.diagnostics.Contains('withheld') -Message 'Privacy fixture did not return stable diagnostics'
        Assert-True -Condition $jsonResult.attempts[0].diagnostics.Contains('withheld') -Message 'Privacy fixture attempt diagnostics were not withheld'

        $textOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker fixture `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 2>&1
        $textExitCode = $LASTEXITCODE
        $textResult = @($textOutput) -join [Environment]::NewLine
        Assert-Equal -Expected 1 -Actual $textExitCode -Message 'Privacy fixture text run returned the wrong exit code'
        Assert-True -Condition (-not $textResult.Contains('unique-privacy-sentinel')) -Message 'Privacy fixture leaked its work order into text diagnostics'
    }

    Invoke-Test -Name 'Public V2 output-limit failures return a stable envelope without partial worker output' -Body {
        $fixtureDirectory = Join-Path $tempRoot 'flood-fixture'
        $workerPath = Join-Path $fixtureDirectory 'claude.ps1'
        $configPath = Join-Path $tempRoot 'flood-run-v2.json'
        $promptPath = Join-Path $tempRoot 'flood-run-prompt.md'
        [void](New-Item -ItemType Directory -Path $fixtureDirectory)
        $fixtureScript = @'
$stream = [Console]::OpenStandardOutput()
$buffer = New-Object byte[] 8192
for ($index = 0; $index -lt 2049; $index++) { $stream.Write($buffer, 0, $buffer.Length) }
Start-Sleep -Seconds 10
'@
        [System.IO.File]::WriteAllText($workerPath, $fixtureScript, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($promptPath, 'flood run prompt')
        $config = New-RoutingFixtureConfig
        $config.workers.fixture.path = $workerPath
        Write-TestJson -Path $configPath -Value $config
        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker fixture `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $runText = @($runOutput) -join [Environment]::NewLine
        $run = $runText | ConvertFrom-Json

        Assert-Equal -Expected 1 -Actual $runExitCode -Message 'Public output-limit run returned the wrong exit code'
        Assert-True -Condition (-not $run.ok) -Message 'Public output-limit run unexpectedly succeeded'
        Assert-Equal -Expected 'output_limit' -Actual $run.failureKind -Message 'Public output-limit failure kind changed'
        Assert-Equal -Expected 'OUTPUT_LIMIT' -Actual $run.error.code -Message 'Public output-limit error code changed'
        Assert-True -Condition $run.outputLimitExceeded -Message 'Public output-limit flag changed'
        Assert-Equal -Expected '' -Actual $run.output -Message 'Public output-limit run returned partial worker output'
        Assert-True -Condition (-not $runText.Contains('AAAAAAAA')) -Message 'Public output-limit run leaked partial output bytes'
    }

    Invoke-Test -Name 'Run invokes a named Claude worker through the public launcher' -Body {
        $workerPath = Join-Path $tempRoot 'claude.ps1'
        $configPath = Join-Path $tempRoot 'run-worker-v2.json'
        $promptPath = Join-Path $tempRoot 'run-worker-prompt.md'
        $expectedPrompt = 'named worker UTF-8 ' + [string][char]0x7B2C + [string][char]0x4E8C
        [System.IO.File]::WriteAllText(
            $workerPath,
            '[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false); [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); [Console]::Write([Console]::In.ReadToEnd())',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $promptPath,
            $expectedPrompt,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                'claude-fixture' = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $workerPath
                    model = 'fixture-model'
                    capabilities = @('text.reason', 'workspace.read')
                    settings = [ordered]@{}
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker 'claude-fixture' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Named worker run returned a non-zero exit code'
        Assert-Equal -Expected 2 -Actual $run.schemaVersion -Message 'Run schema changed'
        Assert-True -Condition $run.ok -Message 'Named worker run failed'
        Assert-Equal -Expected 'run' -Actual $run.command -Message 'Run command changed'
        Assert-Equal -Expected 'claude-fixture' -Actual $run.selection.worker -Message 'Run selected the wrong worker'
        Assert-Equal -Expected 'claude-code/v1' -Actual $run.selection.adapter -Message 'Run selected the wrong adapter'
        Assert-Equal -Expected 'fixture-model' -Actual $run.selection.model -Message 'Run selected the wrong model'
        Assert-Equal -Expected $expectedPrompt -Actual $run.output -Message 'Run changed the UTF-8 work order'
        Assert-Equal -Expected 1 -Actual @($run.attempts).Count -Message 'Direct worker run should have one attempt'
    }

    Invoke-Test -Name 'Run permits a Claude native default model and applies its trusted profile directory' -Body {
        $workerDirectory = Join-Path $tempRoot 'claude-native-default'
        $workerPath = Join-Path $workerDirectory 'claude.ps1'
        $profileDirectory = Join-Path $tempRoot 'claude-native-profile'
        $configPath = Join-Path $tempRoot 'run-claude-native-default-v2.json'
        $promptPath = Join-Path $tempRoot 'run-claude-native-default.md'
        [void](New-Item -ItemType Directory -Path $workerDirectory)
        [void](New-Item -ItemType Directory -Path $profileDirectory)
        [System.IO.File]::WriteAllText(
            $workerPath,
            '$payload = [pscustomobject]@{ configDirectory = $env:CLAUDE_CONFIG_DIR; modelArgumentPresent = ($args -contains ''--model''); prompt = [Console]::In.ReadToEnd() }; [Console]::Write(($payload | ConvertTo-Json -Compress))',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'native model prompt')
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                'claude-native-default' = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $workerPath
                    model = $null
                    capabilities = @('text.reason')
                    settings = [ordered]@{ configDirectory = $profileDirectory }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker 'claude-native-default' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Native-default Claude worker returned a non-zero exit code'
        Assert-True -Condition $run.ok -Message 'Native-default Claude worker failed'
        Assert-True -Condition ($null -eq $run.selection.model) -Message 'Native default model was changed'
        Assert-Equal -Expected $profileDirectory -Actual $run.output.configDirectory -Message 'Claude native profile directory was not applied'
        Assert-True -Condition (-not $run.output.modelArgumentPresent) -Message 'Claude native default unexpectedly received a model argument'
        Assert-Equal -Expected 'native model prompt' -Actual $run.output.prompt -Message 'Native-default Claude worker changed the prompt'
    }

    Invoke-Test -Name 'Run rejects unsupported workspace capability before process creation' -Body {
        $workerPath = Join-Path $tempRoot 'mmx.ps1'
        $markerPath = Join-Path $tempRoot 'minimax-should-not-start.marker'
        $configPath = Join-Path $tempRoot 'run-capability-denied-v2.json'
        $promptPath = Join-Path $tempRoot 'run-capability-denied.md'
        [System.IO.File]::WriteAllText(
            $workerPath,
            ('[System.IO.File]::WriteAllText(''{0}'', ''started'')' -f $markerPath.Replace("'", "''")),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'bounded task')
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                stateless = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $workerPath
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{ region = 'cn' }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker 'stateless' `
            -RequireCapability 'workspace.read' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 2 -Actual $runExitCode -Message 'Capability denial returned the wrong exit code'
        Assert-True -Condition (-not $run.ok) -Message 'Unsupported workspace capability was accepted'
        Assert-Equal -Expected 'CAPABILITY_DENIED' -Actual $run.error.code -Message 'Capability denial error code changed'
        Assert-True -Condition (-not (Test-Path -LiteralPath $markerPath)) -Message 'Capability-denied worker process was started'
    }

    Invoke-Test -Name 'Run selects the first eligible worker from a profile' -Body {
        $workerPath = Join-Path $tempRoot 'claude.ps1'
        $configPath = Join-Path $tempRoot 'run-profile-v2.json'
        $promptPath = Join-Path $tempRoot 'run-profile-prompt.md'
        [System.IO.File]::WriteAllText(
            $workerPath,
            '[void][Console]::In.ReadToEnd(); [Console]::Write(''PROFILE_RUN_OK'')',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'profile task')
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                disabled = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $false
                    path = $null
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{ region = 'cn' }
                }
                primary = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $workerPath
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{}
                }
            }
            profiles = [ordered]@{
                reasoning = [ordered]@{
                    workers = @('disabled', 'primary')
                    fallback = [ordered]@{ maxAttempts = 1; on = @() }
                }
            }
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Profile 'reasoning' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Profile run returned a non-zero exit code'
        Assert-Equal -Expected 'primary' -Actual $run.selection.worker -Message 'Profile selected the wrong worker'
        Assert-Equal -Expected 'reasoning' -Actual $run.selection.resolvedProfile -Message 'Resolved profile changed'
        Assert-Equal -Expected 'PROFILE_RUN_OK' -Actual $run.output -Message 'Profile worker output changed'
        Assert-Equal -Expected 1 -Actual @($run.skipped).Count -Message 'Profile static skip count changed'
        Assert-Equal -Expected 'disabled' -Actual $run.skipped[0].worker -Message 'Profile skipped the wrong worker'
        Assert-Equal -Expected 'disabled' -Actual $run.skipped[0].reason -Message 'Profile skip reason changed'
    }

    Invoke-Test -Name 'Read profile falls back in order only for an explicitly allowed failure kind' -Body {
        $firstDirectory = Join-Path $tempRoot 'fallback-first'
        $secondDirectory = Join-Path $tempRoot 'fallback-second'
        [void](New-Item -ItemType Directory -Path $firstDirectory)
        [void](New-Item -ItemType Directory -Path $secondDirectory)
        $firstWorkerPath = Join-Path $firstDirectory 'claude.ps1'
        $secondWorkerPath = Join-Path $secondDirectory 'claude.ps1'
        $firstMarker = Join-Path $tempRoot 'fallback-first.marker'
        $secondMarker = Join-Path $tempRoot 'fallback-second.marker'
        $configPath = Join-Path $tempRoot 'run-fallback-v2.json'
        $promptPath = Join-Path $tempRoot 'run-fallback-prompt.md'
        [System.IO.File]::WriteAllText(
            $firstWorkerPath,
            ('[void][Console]::In.ReadToEnd(); [System.IO.File]::WriteAllText(''{0}'', ''started''); [Console]::Error.Write(''fixture process failure''); exit 9' -f $firstMarker.Replace("'", "''")),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $secondWorkerPath,
            ('[void][Console]::In.ReadToEnd(); [System.IO.File]::WriteAllText(''{0}'', ''started''); [Console]::Write(''FALLBACK_OK'')' -f $secondMarker.Replace("'", "''")),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'fallback task')
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                first = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $firstWorkerPath
                    model = 'first-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{}
                }
                second = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $secondWorkerPath
                    model = 'second-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{}
                }
            }
            profiles = [ordered]@{
                resilient = [ordered]@{
                    workers = @('first', 'second')
                    fallback = [ordered]@{
                        maxAttempts = 2
                        on = @('process_exit')
                    }
                }
            }
            routes = [ordered]@{}
        }
        Write-TestJson -Path $configPath -Value $runConfig

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Profile 'resilient' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Allowed read fallback returned a non-zero exit code'
        Assert-True -Condition $run.ok -Message 'Allowed read fallback failed'
        Assert-Equal -Expected 'second' -Actual $run.selection.worker -Message 'Fallback did not select the second worker'
        Assert-Equal -Expected 'second-model' -Actual $run.selection.model -Message 'Fallback final model changed'
        Assert-Equal -Expected 'FALLBACK_OK' -Actual $run.output -Message 'Fallback final output changed'
        Assert-Equal -Expected 2 -Actual @($run.attempts).Count -Message 'Fallback attempt count changed'
        Assert-Equal -Expected 'first' -Actual $run.attempts[0].worker -Message 'Fallback first attempt changed'
        Assert-Equal -Expected 'process_exit' -Actual $run.attempts[0].failureKind -Message 'Fallback first failure kind changed'
        Assert-Equal -Expected 'second' -Actual $run.attempts[1].worker -Message 'Fallback second attempt changed'
        Assert-True -Condition (Test-Path -LiteralPath $firstMarker) -Message 'Fallback first worker did not start'
        Assert-True -Condition (Test-Path -LiteralPath $secondMarker) -Message 'Fallback second worker did not start'
    }

    Invoke-Test -Name 'Fallback hard stops on permission denial write mode and NoFallback' -Body {
        $cases = @(
            [pscustomobject]@{
                name = 'permission'
                mode = 'read'
                noFallback = $false
                errorText = 'headless mode cannot prompt; permission denied'
                expectedFailureKind = 'permission_denied'
            },
            [pscustomobject]@{
                name = 'write'
                mode = 'write'
                noFallback = $false
                errorText = 'fixture process failure'
                expectedFailureKind = 'process_exit'
            },
            [pscustomobject]@{
                name = 'no-fallback'
                mode = 'read'
                noFallback = $true
                errorText = 'fixture process failure'
                expectedFailureKind = 'process_exit'
            }
        )

        foreach ($case in $cases) {
            $caseRoot = Join-Path $tempRoot ('hard-stop-{0}' -f $case.name)
            $firstDirectory = Join-Path $caseRoot 'first'
            $secondDirectory = Join-Path $caseRoot 'second'
            [void](New-Item -ItemType Directory -Path $firstDirectory -Force)
            [void](New-Item -ItemType Directory -Path $secondDirectory -Force)
            $firstWorkerPath = Join-Path $firstDirectory 'claude.ps1'
            $secondWorkerPath = Join-Path $secondDirectory 'claude.ps1'
            $firstMarker = Join-Path $caseRoot 'first.marker'
            $secondMarker = Join-Path $caseRoot 'second.marker'
            $configPath = Join-Path $caseRoot 'config.json'
            $promptPath = Join-Path $caseRoot 'prompt.md'
            [System.IO.File]::WriteAllText(
                $firstWorkerPath,
                ('[void][Console]::In.ReadToEnd(); [System.IO.File]::WriteAllText(''{0}'', ''started''); [Console]::Error.Write(''{1}''); exit 9' -f $firstMarker.Replace("'", "''"), $case.errorText.Replace("'", "''")),
                (New-Object System.Text.UTF8Encoding($false))
            )
            [System.IO.File]::WriteAllText(
                $secondWorkerPath,
                ('[void][Console]::In.ReadToEnd(); [System.IO.File]::WriteAllText(''{0}'', ''started''); [Console]::Write(''SHOULD_NOT_RUN'')' -f $secondMarker.Replace("'", "''")),
                (New-Object System.Text.UTF8Encoding($false))
            )
            [System.IO.File]::WriteAllText($promptPath, 'hard stop task')
            $runConfig = [ordered]@{
                schemaVersion = 2
                defaultRoute = $null
                defaultProfile = $null
                workers = [ordered]@{
                    first = [ordered]@{
                        adapter = 'claude-code/v1'
                        enabled = $true
                        path = $firstWorkerPath
                        model = 'first-model'
                        capabilities = @('text.reason', 'workspace.write')
                        settings = [ordered]@{}
                    }
                    second = [ordered]@{
                        adapter = 'claude-code/v1'
                        enabled = $true
                        path = $secondWorkerPath
                        model = 'second-model'
                        capabilities = @('text.reason', 'workspace.write')
                        settings = [ordered]@{}
                    }
                }
                profiles = [ordered]@{
                    guarded = [ordered]@{
                        workers = @('first', 'second')
                        fallback = [ordered]@{
                            maxAttempts = 2
                            on = @('process_exit')
                        }
                    }
                }
                routes = [ordered]@{}
            }
            Write-TestJson -Path $configPath -Value $runConfig

            $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
            $hostPath = Get-CurrentPowerShellExecutable
            $arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-File', $launcherPath,
                'run',
                '-Profile', 'guarded',
                '-PromptFile', $promptPath,
                '-Mode', $case.mode,
                '-WorkingDirectory', $caseRoot,
                '-ConfigPath', $configPath,
                '-TimeoutSeconds', '30',
                '-Json'
            )
            if ($case.noFallback) {
                $arguments += '-NoFallback'
            }
            $runOutput = & $hostPath @arguments
            $runExitCode = $LASTEXITCODE
            $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

            Assert-Equal -Expected 1 -Actual $runExitCode -Message ('Fallback hard-stop returned the wrong exit code: {0}' -f $case.name)
            Assert-True -Condition (-not $run.ok) -Message ('Fallback hard-stop unexpectedly succeeded: {0}' -f $case.name)
            Assert-Equal -Expected 1 -Actual @($run.attempts).Count -Message ('Fallback hard-stop attempt count changed: {0}' -f $case.name)
            Assert-Equal -Expected $case.expectedFailureKind -Actual $run.failureKind -Message ('Fallback hard-stop failure kind changed: {0}' -f $case.name)
            Assert-True -Condition (Test-Path -LiteralPath $firstMarker) -Message ('Fallback hard-stop first worker did not start: {0}' -f $case.name)
            Assert-True -Condition (-not (Test-Path -LiteralPath $secondMarker)) -Message ('Fallback hard-stop launched a second worker: {0}' -f $case.name)
        }
    }

    Invoke-Test -Name 'Run route capabilities take priority over worker order' -Body {
        $miniMaxPath = Join-Path $tempRoot 'mmx.ps1'
        $claudePath = Join-Path $tempRoot 'claude.ps1'
        $miniMaxMarker = Join-Path $tempRoot 'route-minimax-started.marker'
        $configPath = Join-Path $tempRoot 'run-route-v2.json'
        $promptPath = Join-Path $tempRoot 'run-route-prompt.md'
        [System.IO.File]::WriteAllText(
            $miniMaxPath,
            ('[System.IO.File]::WriteAllText(''{0}'', ''started'')' -f $miniMaxMarker.Replace("'", "''")),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $claudePath,
            '[void][Console]::In.ReadToEnd(); [Console]::Write(''ROUTE_RUN_OK'')',
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText($promptPath, 'repository review task')
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                stateless = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $miniMaxPath
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{ region = 'cn' }
                }
                repository = [ordered]@{
                    adapter = 'claude-code/v1'
                    enabled = $true
                    path = $claudePath
                    model = 'fixture-model'
                    capabilities = @('text.reason', 'workspace.read')
                    settings = [ordered]@{}
                }
            }
            profiles = [ordered]@{
                paid = [ordered]@{
                    workers = @('stateless', 'repository')
                    fallback = [ordered]@{ maxAttempts = 1; on = @() }
                }
            }
            routes = [ordered]@{
                'repo-review' = [ordered]@{
                    profile = 'paid'
                    requiredCapabilities = @('text.reason', 'workspace.read')
                    defaultMode = 'read'
                    allowedModes = @('read')
                }
            }
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Route 'repo-review' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Route run returned a non-zero exit code'
        Assert-Equal -Expected 'repository' -Actual $run.selection.worker -Message 'Route selected a capability-ineligible worker'
        Assert-Equal -Expected 'paid' -Actual $run.selection.resolvedProfile -Message 'Route resolved the wrong profile'
        Assert-Equal -Expected 'ROUTE_RUN_OK' -Actual $run.output -Message 'Route worker output changed'
        Assert-Equal -Expected 'capability_denied' -Actual $run.skipped[0].reason -Message 'Route skip reason changed'
        Assert-True -Condition (-not (Test-Path -LiteralPath $miniMaxMarker)) -Message 'Capability-ineligible worker process was started'
    }

    Invoke-Test -Name 'Run invokes a named MiniMax worker through an ephemeral UTF-8 message file' -Body {
        $workerPath = Join-Path $tempRoot 'mmx.ps1'
        $configDirectory = Join-Path $tempRoot 'mmx-config'
        $configPath = Join-Path $tempRoot 'run-minimax-v2.json'
        $promptPath = Join-Path $tempRoot 'run-minimax-prompt.md'
        $expectedPrompt = 'MiniMax UTF-8 ' + [string][char]0x5DE5 + [string][char]0x4F5C + [string][char]0x5355
        [void](New-Item -ItemType Directory -Path $configDirectory)
        $fixtureScript = @'
$messagesIndex = [Array]::IndexOf([object[]]$args, '--messages-file')
$baseUrlIndex = [Array]::IndexOf([object[]]$args, '--base-url')
if ($messagesIndex -lt 0 -or $baseUrlIndex -lt 0) { exit 41 }
$messagesPath = [string]$args[$messagesIndex + 1]
$messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$result = [pscustomobject]@{
    prompt = [string]$messages[0].content
    messagesFile = $messagesPath
    argumentBaseUrl = [string]$args[$baseUrlIndex + 1]
    environmentBaseUrl = [string]$env:MINIMAX_BASE_URL
    environmentConfigDirectory = [string]$env:MMX_CONFIG_DIR
}
[Console]::Write(($result | ConvertTo-Json -Compress))
'@
        [System.IO.File]::WriteAllText(
            $workerPath,
            $fixtureScript,
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $promptPath,
            $expectedPrompt,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                'minimax-fixture' = [ordered]@{
                    adapter = 'minimax-cli/v1'
                    enabled = $true
                    path = $workerPath
                    model = 'fixture-model'
                    capabilities = @('text.reason')
                    settings = [ordered]@{
                        region = 'cn'
                        configDirectory = $configDirectory
                    }
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker 'minimax-fixture' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Named MiniMax run returned a non-zero exit code'
        Assert-True -Condition $run.ok -Message 'Named MiniMax run failed'
        Assert-Equal -Expected 'minimax-cli/v1' -Actual $run.selection.adapter -Message 'MiniMax run selected the wrong adapter'
        Assert-Equal -Expected $expectedPrompt -Actual $run.output.prompt -Message 'MiniMax run changed the UTF-8 work order'
        Assert-Equal -Expected 'https://api.minimaxi.com' -Actual $run.output.argumentBaseUrl -Message 'MiniMax CN region argument endpoint changed'
        Assert-Equal -Expected 'https://api.minimaxi.com' -Actual $run.output.environmentBaseUrl -Message 'MiniMax CN region environment endpoint changed'
        Assert-Equal -Expected $configDirectory -Actual $run.output.environmentConfigDirectory -Message 'MiniMax config directory was not isolated through MMX_CONFIG_DIR'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Split-Path -Parent $run.output.messagesFile))) -Message 'MiniMax ephemeral message directory was not removed'
    }

    Invoke-Test -Name 'Run invokes a named Antigravity worker with sandboxed workspace scoping' -Body {
        $workerPath = Join-Path $tempRoot 'agy.ps1'
        $configPath = Join-Path $tempRoot 'run-antigravity-v2.json'
        $promptPath = Join-Path $tempRoot 'run-antigravity-prompt.md'
        $expectedPrompt = 'Antigravity UTF-8 ' + [string][char]0x5BA1 + [string][char]0x67E5
        $fixtureScript = @'
$printIndex = [Array]::IndexOf([object[]]$args, '--print')
$modelIndex = [Array]::IndexOf([object[]]$args, '--model')
$modeIndex = [Array]::IndexOf([object[]]$args, '--mode')
$timeoutIndex = [Array]::IndexOf([object[]]$args, '--print-timeout')
$addDirectories = @()
for ($index = 0; $index -lt $args.Count; $index++) {
    if ([string]$args[$index] -eq '--add-dir') {
        $addDirectories += [string]$args[$index + 1]
    }
}
if ($printIndex -lt 0 -or $addDirectories.Count -ne 2) { exit 42 }
$workOrderDirectory = $addDirectories[1]
$workOrderPath = Join-Path $workOrderDirectory 'work-order.md'
$result = [pscustomobject]@{
    prompt = [System.IO.File]::ReadAllText($workOrderPath, (New-Object System.Text.UTF8Encoding($false, $true)))
    workOrderFile = $workOrderPath
    printInstruction = [string]$args[$printIndex + 1]
    model = [string]$args[$modelIndex + 1]
    mode = [string]$args[$modeIndex + 1]
    timeout = [string]$args[$timeoutIndex + 1]
    sandbox = ([Array]::IndexOf([object[]]$args, '--sandbox') -ge 0)
    outputFormat = [string]$args[[Array]::IndexOf([object[]]$args, '--output-format') + 1]
    addDirectories = $addDirectories
    workingDirectory = [Environment]::CurrentDirectory
    argumentText = [string]::Join(' ', [string[]]$args)
}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::Write(($result | ConvertTo-Json -Depth 5 -Compress))
'@
        [System.IO.File]::WriteAllText(
            $workerPath,
            $fixtureScript,
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $promptPath,
            $expectedPrompt,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $runConfig = [ordered]@{
            schemaVersion = 2
            defaultRoute = $null
            defaultProfile = $null
            workers = [ordered]@{
                'antigravity-fixture' = [ordered]@{
                    adapter = 'antigravity/v1'
                    enabled = $true
                    path = $workerPath
                    model = 'fixture-model'
                    capabilities = @('text.reason', 'workspace.read')
                    settings = [ordered]@{}
                }
            }
            profiles = [ordered]@{}
            routes = [ordered]@{}
        }
        [System.IO.File]::WriteAllText(
            $configPath,
            (ConvertTo-Json -InputObject $runConfig -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $launcherPath = Join-Path $orchestratorRoot 'bin\aiw.ps1'
        $hostPath = Get-CurrentPowerShellExecutable
        $runOutput = & $hostPath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -File $launcherPath `
            run `
            -Worker 'antigravity-fixture' `
            -RequireCapability 'workspace.read' `
            -PromptFile $promptPath `
            -Mode read `
            -WorkingDirectory $tempRoot `
            -ConfigPath $configPath `
            -TimeoutSeconds 30 `
            -Json
        $runExitCode = $LASTEXITCODE
        $run = (@($runOutput) -join [Environment]::NewLine) | ConvertFrom-Json

        Assert-Equal -Expected 0 -Actual $runExitCode -Message 'Named Antigravity run returned a non-zero exit code'
        Assert-True -Condition $run.ok -Message 'Named Antigravity run failed'
        Assert-Equal -Expected 'antigravity/v1' -Actual $run.selection.adapter -Message 'Antigravity run selected the wrong adapter'
        Assert-Equal -Expected $expectedPrompt -Actual $run.output.prompt -Message 'Antigravity run changed the UTF-8 work order'
        Assert-Equal -Expected 'fixture-model' -Actual $run.output.model -Message 'Antigravity model argument changed'
        Assert-Equal -Expected 'plan' -Actual $run.output.mode -Message 'Antigravity read mode was not bounded to plan'
        Assert-Equal -Expected '30s' -Actual $run.output.timeout -Message 'Antigravity print timeout changed'
        Assert-Equal -Expected 'text' -Actual $run.output.outputFormat -Message 'Antigravity output format changed'
        Assert-True -Condition $run.output.sandbox -Message 'Antigravity sandbox flag was omitted'
        Assert-Equal -Expected $tempRoot -Actual $run.output.addDirectories[0] -Message 'Antigravity canonical workspace registration changed'
        Assert-Equal -Expected $tempRoot -Actual $run.output.workingDirectory -Message 'Antigravity process working directory changed'
        Assert-True -Condition (-not $run.output.argumentText.Contains($expectedPrompt)) -Message 'Antigravity prompt leaked into process arguments'
        Assert-True -Condition $run.output.printInstruction.Contains($run.output.workOrderFile) -Message 'Antigravity print instruction did not reference the controlled work order'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Split-Path -Parent $run.output.workOrderFile))) -Message 'Antigravity ephemeral work-order directory was not removed'
    }

    Write-Output ('All {0} tests passed.' -f $script:Passed)
} finally {
    $resolvedTempBase = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path
    $resolvedTestRoot = (Resolve-Path -LiteralPath $tempRoot).Path
    if ($resolvedTestRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
