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

    [ValidateSet(1, 2)]
    [int]$OutputSchema = 1,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AiwCoreModulePath = Join-Path $PSScriptRoot 'src\Aiw.Core.psm1'
Import-Module -Name $script:AiwCoreModulePath -Force -ErrorAction Stop

$script:AiwVersionPath = Join-Path $PSScriptRoot 'version.json'
try {
    $versionDocument = [System.IO.File]::ReadAllText($script:AiwVersionPath) | ConvertFrom-Json
    $versionProperty = $versionDocument.PSObject.Properties['productVersion']
    if ($null -eq $versionProperty) {
        throw 'Missing productVersion.'
    }
    $script:AiwVersion = ([string]$versionProperty.Value).Trim()
    if ($script:AiwVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw 'Invalid productVersion.'
    }
} catch {
    throw 'AIW version metadata is missing or invalid.'
}
$script:MaxWorkerStreamBytes = 16777216
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

function Resolve-AiwCoreConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [System.IO.Path]::GetFullPath($ConfigPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:AIW_CONFIG_PATH)) {
        return [System.IO.Path]::GetFullPath($env:AIW_CONFIG_PATH)
    }

    $candidate = Join-Path $env:USERPROFILE '.aiw\config.json'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    return $null
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
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$PromptText
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)\bsk-[A-Za-z0-9_-]{8,}\b', '[REDACTED]'
    $sanitized = $sanitized -replace '(?i)\b(API[_-]?KEY|AUTHORIZATION|AUTH[_-]?TOKEN|TOKEN)\s*([:=])\s*\S+', '$1$2[REDACTED]'
    if (-not [string]::IsNullOrWhiteSpace($PromptText)) {
        $sanitized = $sanitized.Replace($PromptText, '[REDACTED_WORK_ORDER]')
    }
    return $sanitized.TrimEnd()
}

function Get-PublicWorkerDiagnostics {
    param([Parameter(Mandatory)][object]$Result)

    $trustedOverride = [string](Get-AiwProperty `
        -Object $Result `
        -Name 'PublicDiagnosticsOverride' `
        -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($trustedOverride)) {
        return $trustedOverride
    }

    $standardError = [string](Get-AiwProperty -Object $Result -Name 'StandardError' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($standardError)) {
        return $null
    }

    # Provider stderr is untrusted: it can contain work-order text, secrets, or
    # terminal formatting. FailureKind remains the structured diagnostic signal.
    return 'Worker diagnostic output was withheld from the public result.'
}

function ConvertTo-NativeArgument {
    param(
        [AllowEmptyString()][string]$Value,
        [switch]$AlwaysQuote
    )

    if (-not $AlwaysQuote -and
        $Value.Length -gt 0 -and
        $Value -notmatch '[\s"]') {
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

function ConvertTo-ReviewedCmdToken {
    param([AllowEmptyString()][string]$Value)

    if ($Value -match '[\x00-\x1F\x7F"&|<>^%!]') {
        throw 'MiniMax batch argument contains a character that is unsafe for cmd.exe.'
    }

    return (ConvertTo-NativeArgument -Value $Value -AlwaysQuote)
}

function New-WorkerProcessStartInfo {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Directory,

        [bool]$RedirectStandardInput,

        [bool]$AllowBatchWorker
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $launchPath = $FilePath
    $launchArguments = $Arguments
    $launchArgumentText = $null

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
        $leafName = [System.IO.Path]::GetFileName($FilePath)
        if (-not $leafName.Equals(
            'mmx.cmd',
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Only the reviewed MiniMax mmx.cmd wrapper may use batch launch.'
        }
        $systemDirectory = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::System
        )
        $launchPath = Join-Path $systemDirectory 'cmd.exe'
        if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
            throw 'System cmd.exe is unavailable for the reviewed MiniMax wrapper.'
        }
        $batchCommand = (@($FilePath) + @($Arguments) | ForEach-Object {
            ConvertTo-ReviewedCmdToken -Value ([string]$_)
        }) -join ' '
        $launchArgumentText = '/d /v:off /s /c "' + $batchCommand + '"'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launchPath
    $startInfo.Arguments = if ($null -ne $launchArgumentText) {
        $launchArgumentText
    } else {
        ($launchArguments | ForEach-Object {
            ConvertTo-NativeArgument -Value ([string]$_)
        }) -join ' '
    }
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

function Initialize-AiwJobObjectInterop {
    if ($null -ne ('AiwOrchestrator.NativeJobObject' -as [type]) -and
        $null -ne ('AiwOrchestrator.SuspendedWorkerProcess' -as [type]) -and
        $null -ne ('AiwOrchestrator.BoundedStreamCapture' -as [type])) {
        return $true
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace AiwOrchestrator
{
    public static class NativeJobObject
    {
        public const string Library = "kernel32.dll";

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);

        public static bool EnableKillOnClose(IntPtr job)
        {
            AiwJobObjectExtendedLimitInformation information =
                new AiwJobObjectExtendedLimitInformation();
            information.BasicLimitInformation.LimitFlags = 0x00002000;
            int size = Marshal.SizeOf(typeof(AiwJobObjectExtendedLimitInformation));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, buffer, false);
                return SetInformationJobObject(job, 9, buffer, (uint)size);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AiwJobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AiwIoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AiwJobObjectExtendedLimitInformation
    {
        public AiwJobObjectBasicLimitInformation BasicLimitInformation;
        public AiwIoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AiwSecurityAttributes
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct AiwStartupInfo
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct AiwStartupInfoEx
    {
        public AiwStartupInfo StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AiwProcessInformation
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    internal static class AiwNativeProcess
    {
        internal const uint CreateSuspended = 0x00000004;
        internal const uint CreateNoWindow = 0x08000000;
        internal const uint ExtendedStartupInfoPresent = 0x00080000;
        internal const uint StartfUseStdHandles = 0x00000100;
        internal const uint HandleFlagInherit = 0x00000001;
        internal static readonly IntPtr ProcThreadAttributeHandleList =
            new IntPtr(0x00020002);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref AiwSecurityAttributes attributes,
            uint size); // pipe size

        [DllImport(NativeJobObject.Library, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags);

        [DllImport(NativeJobObject.Library, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            uint flags,
            ref IntPtr size);

        [DllImport(NativeJobObject.Library, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport(NativeJobObject.Library)]
        internal static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport(
            NativeJobObject.Library,
            EntryPoint = "CreateProcessW",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcessWithAttributes(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref AiwStartupInfoEx startupInfo,
            out AiwProcessInformation processInformation);

        [DllImport(NativeJobObject.Library, SetLastError = true)]
        internal static extern uint ResumeThread(IntPtr threadHandle);

        [DllImport(NativeJobObject.Library, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);

        internal static void CloseQuietly(ref IntPtr handle)
        {
            if (handle == IntPtr.Zero) return;
            NativeJobObject.CloseHandle(handle);
            handle = IntPtr.Zero;
        }

        internal static void ThrowLastError()
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    internal sealed class AiwHandleAllowList : IDisposable
    {
        private IntPtr attributeList;
        private IntPtr handleValues;
        private bool initialized;

        internal IntPtr Pointer
        {
            get { return attributeList; }
        }

        internal AiwHandleAllowList(params IntPtr[] handles)
        {
            if (handles == null || handles.Length == 0)
                throw new ArgumentException(
                    "At least one inheritable handle is required.",
                    "handles");

            try
            {
                IntPtr attributeBytes = IntPtr.Zero;
                AiwNativeProcess.InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeBytes);
                if (attributeBytes == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error());

                attributeList = Marshal.AllocHGlobal(attributeBytes);
                if (!AiwNativeProcess.InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeBytes))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized = true;

                int byteCount = checked(IntPtr.Size * handles.Length);
                handleValues = Marshal.AllocHGlobal(byteCount);
                for (int index = 0; index < handles.Length; index++)
                {
                    long value = handles[index].ToInt64();
                    if (value == 0 || value == -1 || value == -2)
                        throw new ArgumentException(
                            "Handle list contains an invalid or pseudo handle.",
                            "handles");
                    Marshal.WriteIntPtr(
                        handleValues,
                        index * IntPtr.Size,
                        handles[index]);
                }

                if (!AiwNativeProcess.UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    AiwNativeProcess.ProcThreadAttributeHandleList,
                    handleValues,
                    new IntPtr(byteCount),
                    IntPtr.Zero,
                    IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            if (initialized && attributeList != IntPtr.Zero)
            {
                AiwNativeProcess.DeleteProcThreadAttributeList(attributeList);
                initialized = false;
            }
            if (handleValues != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(handleValues);
                handleValues = IntPtr.Zero;
            }
            if (attributeList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(attributeList);
                attributeList = IntPtr.Zero;
            }
        }
    }

    public sealed class SuspendedWorkerProcess : IDisposable
    {
        public Process Process { get; private set; }
        public Stream StandardInput { get; private set; }
        public Stream StandardOutput { get; private set; }
        public Stream StandardError { get; private set; }

        private IntPtr threadHandle;
        private bool disposed;
        private readonly Encoding standardInputEncoding = new UTF8Encoding(false);

        private SuspendedWorkerProcess(
            Process process,
            Stream standardInput,
            Stream standardOutput,
            Stream standardError,
            IntPtr primaryThread)
        {
            Process = process;
            StandardInput = standardInput;
            StandardOutput = standardOutput;
            StandardError = standardError;
            threadHandle = primaryThread;
        }

        public bool Resume()
        {
            if (threadHandle == IntPtr.Zero) return false;
            IntPtr handle = threadHandle;
            threadHandle = IntPtr.Zero;
            try
            {
                return AiwNativeProcess.ResumeThread(handle) != UInt32.MaxValue;
            }
            finally
            {
                NativeJobObject.CloseHandle(handle);
            }
        }

        public static SuspendedWorkerProcess Start(
            string applicationPath,
            string arguments,
            string workingDirectory)
        {
            if (String.IsNullOrWhiteSpace(applicationPath))
                throw new ArgumentException();
            if (String.IsNullOrWhiteSpace(workingDirectory))
                throw new ArgumentException();

            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            IntPtr processHandle = IntPtr.Zero;
            IntPtr threadHandle = IntPtr.Zero;
            Process process = null;
            Stream standardInput = null;
            Stream standardOutput = null;
            Stream standardError = null;
            try
            {
                AiwSecurityAttributes attributes = new AiwSecurityAttributes();
                attributes.nLength = Marshal.SizeOf(typeof(AiwSecurityAttributes));
                attributes.bInheritHandle = true;

                if (!AiwNativeProcess.CreatePipe(out stdinRead, out stdinWrite, ref attributes, 0))
                    AiwNativeProcess.ThrowLastError();
                if (!AiwNativeProcess.SetHandleInformation(
                    stdinWrite,
                    AiwNativeProcess.HandleFlagInherit,
                    0))
                    AiwNativeProcess.ThrowLastError();

                if (!AiwNativeProcess.CreatePipe(out stdoutRead, out stdoutWrite, ref attributes, 0))
                    AiwNativeProcess.ThrowLastError();
                if (!AiwNativeProcess.SetHandleInformation(
                    stdoutRead,
                    AiwNativeProcess.HandleFlagInherit,
                    0))
                    AiwNativeProcess.ThrowLastError();

                if (!AiwNativeProcess.CreatePipe(out stderrRead, out stderrWrite, ref attributes, 0))
                    AiwNativeProcess.ThrowLastError();
                if (!AiwNativeProcess.SetHandleInformation(
                    stderrRead,
                    AiwNativeProcess.HandleFlagInherit,
                    0))
                    AiwNativeProcess.ThrowLastError();

                AiwStartupInfoEx startup = new AiwStartupInfoEx();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(AiwStartupInfoEx));
                startup.StartupInfo.dwFlags = AiwNativeProcess.StartfUseStdHandles;
                startup.StartupInfo.hStdInput = stdinRead;
                startup.StartupInfo.hStdOutput = stdoutWrite;
                startup.StartupInfo.hStdError = stderrWrite;

                string quote = ((char)34).ToString();
                string commandLine = quote + applicationPath + quote;
                if (!String.IsNullOrWhiteSpace(arguments))
                    commandLine += ((char)32).ToString() + arguments;
                StringBuilder mutableCommandLine = new StringBuilder(commandLine);
                AiwProcessInformation processInformation;
                using (AiwHandleAllowList allowList = new AiwHandleAllowList(
                    stdinRead,
                    stdoutWrite,
                    stderrWrite))
                {
                    startup.lpAttributeList = allowList.Pointer;
                    bool created = AiwNativeProcess.CreateProcessWithAttributes(
                        applicationPath,
                        mutableCommandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        AiwNativeProcess.CreateSuspended |
                            AiwNativeProcess.CreateNoWindow |
                            AiwNativeProcess.ExtendedStartupInfoPresent,
                        IntPtr.Zero,
                        workingDirectory,
                        ref startup,
                        out processInformation);
                    if (!created)
                    {
                        int createError = Marshal.GetLastWin32Error();
                        throw new Win32Exception(createError);
                    }
                }

                processHandle = processInformation.hProcess;
                threadHandle = processInformation.hThread;
                AiwNativeProcess.CloseQuietly(ref stdinRead);
                AiwNativeProcess.CloseQuietly(ref stdoutWrite);
                AiwNativeProcess.CloseQuietly(ref stderrWrite);
                process = Process.GetProcessById((int)processInformation.dwProcessId);

                standardInput = new FileStream(
                    new SafeFileHandle(stdinWrite, true),
                    FileAccess.Write,
                    4096,
                    false);
                stdinWrite = IntPtr.Zero;
                standardOutput = new FileStream(
                    new SafeFileHandle(stdoutRead, true),
                    FileAccess.Read,
                    4096,
                    false);
                stdoutRead = IntPtr.Zero;
                standardError = new FileStream(
                    new SafeFileHandle(stderrRead, true),
                    FileAccess.Read,
                    4096,
                    false);
                stderrRead = IntPtr.Zero;

                AiwNativeProcess.CloseQuietly(ref processHandle);
                SuspendedWorkerProcess result = new SuspendedWorkerProcess(
                    process,
                    standardInput,
                    standardOutput,
                    standardError,
                    threadHandle);
                process = null;
                standardInput = null;
                standardOutput = null;
                standardError = null;
                threadHandle = IntPtr.Zero;
                return result;
            }
            catch
            {
                if (processHandle != IntPtr.Zero)
                    AiwNativeProcess.TerminateProcess(processHandle, 1);
                if (standardInput != null) standardInput.Dispose();
                if (standardOutput != null) standardOutput.Dispose();
                if (standardError != null) standardError.Dispose();
                if (process != null) process.Dispose();
                throw;
            }
            finally
            {
                AiwNativeProcess.CloseQuietly(ref stdinRead);
                AiwNativeProcess.CloseQuietly(ref stdinWrite);
                AiwNativeProcess.CloseQuietly(ref stdoutRead);
                AiwNativeProcess.CloseQuietly(ref stdoutWrite);
                AiwNativeProcess.CloseQuietly(ref stderrRead);
                AiwNativeProcess.CloseQuietly(ref stderrWrite);
                AiwNativeProcess.CloseQuietly(ref processHandle);
                AiwNativeProcess.CloseQuietly(ref threadHandle);
            }
        }

        public Task WriteAndCloseInputAsync(string text)
        {
            if (StandardInput == null) return Task.FromResult(0);
            return WriteAndCloseInputCoreAsync(text ?? String.Empty);
        }

        private async Task WriteAndCloseInputCoreAsync(string text)
        {
            Stream input = StandardInput;
            if (input == null) return;
            try
            {
                byte[] bytes = standardInputEncoding.GetBytes(text);
                await input.WriteAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                await input.FlushAsync().ConfigureAwait(false);
            }
            finally
            {
                if (Object.ReferenceEquals(StandardInput, input)) StandardInput = null;
                input.Dispose();
            }
        }

        public void CloseInput()
        {
            Stream input = StandardInput;
            StandardInput = null;
            if (input != null) input.Dispose();
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            CloseInput();
            if (StandardOutput != null) StandardOutput.Dispose();
            if (StandardError != null) StandardError.Dispose();
            StandardOutput = null;
            StandardError = null;
            if (threadHandle != IntPtr.Zero)
            {
                NativeJobObject.CloseHandle(threadHandle);
                threadHandle = IntPtr.Zero;
            }
            if (Process != null) Process.Dispose();
            Process = null;
        }
    }

    public sealed class BoundedStreamCapture
    {
        private readonly Stream stream;
        private readonly int maximumBytes;
        private volatile bool limitExceeded;

        public bool LimitExceeded
        {
            get { return limitExceeded; }
        }

        public Task<string> Completion { get; private set; }

        public BoundedStreamCapture(Stream stream, int maximumBytes)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            if (maximumBytes < 1) throw new ArgumentOutOfRangeException("maximumBytes");
            this.stream = stream;
            this.maximumBytes = maximumBytes;
            Completion = ReadAsync();
        }

        private async Task<string> ReadAsync()
        {
            byte[] buffer = new byte[8192];
            using (MemoryStream captured = new MemoryStream())
            {
                while (true)
                {
                    int count = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (count <= 0) break;
                    if (!limitExceeded)
                    {
                        if (captured.Length + count > maximumBytes)
                        {
                            limitExceeded = true;
                            continue;
                        }
                        captured.Write(buffer, 0, count);
                    }
                }
                if (limitExceeded) return string.Empty;
                return new UTF8Encoding(false, false).GetString(captured.ToArray());
            }
        }
    }
}
'@ -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function New-WorkerJobObject {
    if (-not (Initialize-AiwJobObjectInterop)) {
        return [System.IntPtr]::Zero
    }

    try {
        $handle = [AiwOrchestrator.NativeJobObject]::CreateJobObject([System.IntPtr]::Zero, $null)
        if ($handle -eq [System.IntPtr]::Zero -or $handle -eq [System.IntPtr](-1)) {
            return [System.IntPtr]::Zero
        }
        if (-not [AiwOrchestrator.NativeJobObject]::EnableKillOnClose($handle)) {
            [void][AiwOrchestrator.NativeJobObject]::CloseHandle($handle)
            return [System.IntPtr]::Zero
        }
        return $handle
    } catch {
        return [System.IntPtr]::Zero
    }
}

function Add-WorkerProcessToJobObject {
    param(
        [Parameter(Mandatory)][System.IntPtr]$JobHandle,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process
    )

    if ($JobHandle -eq [System.IntPtr]::Zero) {
        return $false
    }
    try {
        return [AiwOrchestrator.NativeJobObject]::AssignProcessToJobObject($JobHandle, $Process.Handle)
    } catch {
        return $false
    }
}

function Stop-WorkerJobObject {
    param([Parameter(Mandatory)][System.IntPtr]$JobHandle)

    if ($JobHandle -eq [System.IntPtr]::Zero) {
        return $false
    }
    try {
        return [AiwOrchestrator.NativeJobObject]::TerminateJobObject($JobHandle, 124)
    } catch {
        return $false
    }
}

function Close-WorkerJobObject {
    param([Parameter(Mandatory)][System.IntPtr]$JobHandle)

    if ($JobHandle -eq [System.IntPtr]::Zero) {
        return
    }
    try {
        [void][AiwOrchestrator.NativeJobObject]::CloseHandle($JobHandle)
    } catch {
        # The worker has already been contained or stopped; handle cleanup is best-effort.
    }
}

function Stop-WorkerProcessTree {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [System.IntPtr]$JobHandle = [System.IntPtr]::Zero,

        [bool]$JobAssigned = $false
    )

    if ($Process.HasExited) {
        if ($JobAssigned -and (Stop-WorkerJobObject -JobHandle $JobHandle)) {
            return [pscustomobject]@{
                processTerminated = $true
                treeTerminationConfirmed = $true
                strategy = 'job-object-root-exited'
            }
        }
        return [pscustomobject]@{
            processTerminated = $true
            treeTerminationConfirmed = $false
            strategy = 'already-exited'
        }
    }

    $terminated = $false
    if ($JobAssigned -and (Stop-WorkerJobObject -JobHandle $JobHandle)) {
        $terminated = $Process.WaitForExit(10000)
        if (-not $terminated) {
            $terminated = $Process.HasExited
        }
        if ($terminated) {
            return [pscustomobject]@{
                processTerminated = $true
                treeTerminationConfirmed = $true
                strategy = 'job-object'
            }
        }
    }

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

    return [pscustomobject]@{
        processTerminated = ($terminated -or $Process.HasExited)
        treeTerminationConfirmed = $false
        strategy = 'taskkill-fallback'
    }
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
        [AllowEmptyString()]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateRange(1, 3600)]
        [int]$ProcessTimeoutSeconds,

        [int]$ProcessTimeoutMilliseconds = 0,

        [AllowNull()]
        [string]$StandardInputText,

        [switch]$AllowBatchWorker
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Worker executable not found: $FilePath"
    }

    $hasStandardInput = $null -ne $StandardInputText
    $startInfo = New-WorkerProcessStartInfo -FilePath $FilePath -Arguments $Arguments -Directory $Directory -RedirectStandardInput $hasStandardInput -AllowBatchWorker $AllowBatchWorker
    $process = $null
    $nativeWorker = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $terminationSucceeded = $true
    $treeTerminationConfirmed = $false
    $jobHandle = [System.IntPtr]::Zero
    $jobAssigned = $false
    $outputLimitExceeded = $false
    $stdoutCapture = $null
    $stderrCapture = $null
    $stdoutTask = $null
    $stderrTask = $null
    $inputTask = $null
    $inputWriteFailed = $false

    try {
        if (-not (Initialize-AiwJobObjectInterop)) {
            throw 'Worker containment and bounded stream capture are unavailable on this host.'
        }

        $jobHandle = New-WorkerJobObject
        if ($jobHandle -eq [System.IntPtr]::Zero) {
            throw 'Worker process containment could not be initialized.'
        }

        $nativeWorker = [AiwOrchestrator.SuspendedWorkerProcess]::Start(
            [string]$startInfo.FileName,
            [string]$startInfo.Arguments,
            [string]$startInfo.WorkingDirectory
        )
        $process = $nativeWorker.Process

        $jobAssigned = Add-WorkerProcessToJobObject -JobHandle $jobHandle -Process $process
        if (-not $jobAssigned) {
            $nativeWorker.CloseInput()
            $termination = Stop-WorkerProcessTree `
                -Process $process `
                -JobHandle $jobHandle `
                -JobAssigned $false
            $terminationSucceeded = $termination.processTerminated
            $treeTerminationConfirmed = $termination.treeTerminationConfirmed
            throw 'Worker process containment could not be established.'
        }

        $stdoutCapture = [AiwOrchestrator.BoundedStreamCapture]::new(
            $nativeWorker.StandardOutput,
            [int]$script:MaxWorkerStreamBytes
        )
        $stderrCapture = [AiwOrchestrator.BoundedStreamCapture]::new(
            $nativeWorker.StandardError,
            [int]$script:MaxWorkerStreamBytes
        )
        $stdoutTask = $stdoutCapture.Completion
        $stderrTask = $stderrCapture.Completion

        if (-not $nativeWorker.Resume()) {
            $nativeWorker.CloseInput()
            $termination = Stop-WorkerProcessTree `
                -Process $process `
                -JobHandle $jobHandle `
                -JobAssigned $jobAssigned
            $terminationSucceeded = $termination.processTerminated
            $treeTerminationConfirmed = $termination.treeTerminationConfirmed
            throw 'Worker process could not be resumed after containment was established.'
        }

        if ($hasStandardInput) {
            $inputTask = $nativeWorker.WriteAndCloseInputAsync($StandardInputText)
        } else {
            $nativeWorker.CloseInput()
        }

        $effectiveTimeoutMilliseconds = if ($ProcessTimeoutMilliseconds -gt 0) {
            $ProcessTimeoutMilliseconds
        } else {
            $ProcessTimeoutSeconds * 1000
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($effectiveTimeoutMilliseconds)
        while (-not $process.HasExited) {
            if ($null -ne $inputTask -and ($inputTask.IsFaulted -or $inputTask.IsCanceled)) {
                $inputWriteFailed = $true
                $nativeWorker.CloseInput()
                $termination = Stop-WorkerProcessTree `
                    -Process $process `
                    -JobHandle $jobHandle `
                    -JobAssigned $jobAssigned
                $terminationSucceeded = $termination.processTerminated
                $treeTerminationConfirmed = $termination.treeTerminationConfirmed
                break
            }

            if ($stdoutCapture.LimitExceeded -or $stderrCapture.LimitExceeded) {
                $outputLimitExceeded = $true
                $nativeWorker.CloseInput()
                $termination = Stop-WorkerProcessTree `
                    -Process $process `
                    -JobHandle $jobHandle `
                    -JobAssigned $jobAssigned
                $terminationSucceeded = $termination.processTerminated
                $treeTerminationConfirmed = $termination.treeTerminationConfirmed
                break
            }

            $remainingMilliseconds = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) {
                $timedOut = $true
                $nativeWorker.CloseInput()
                $termination = Stop-WorkerProcessTree `
                    -Process $process `
                    -JobHandle $jobHandle `
                    -JobAssigned $jobAssigned
                $terminationSucceeded = $termination.processTerminated
                $treeTerminationConfirmed = $termination.treeTerminationConfirmed
                break
            }

            Start-Sleep -Milliseconds ([Math]::Min(100, [Math]::Max(1, $remainingMilliseconds)))
        }

        if (-not $timedOut -and -not $outputLimitExceeded -and -not $inputWriteFailed) {
            $process.WaitForExit()
            $nativeWorker.CloseInput()
            if ($jobAssigned) {
                # A worker may not leave background processes behind after its root exits.
                $treeTerminationConfirmed = Stop-WorkerJobObject -JobHandle $jobHandle
            }
        }

        if (-not $timedOut -and -not $outputLimitExceeded -and $null -ne $inputTask) {
            $remainingMilliseconds = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -le 0) {
                $timedOut = $true
                $nativeWorker.CloseInput()
                if (-not $treeTerminationConfirmed) {
                    $termination = Stop-WorkerProcessTree `
                        -Process $process `
                        -JobHandle $jobHandle `
                        -JobAssigned $jobAssigned
                    $terminationSucceeded = $termination.processTerminated
                    $treeTerminationConfirmed = $termination.treeTerminationConfirmed
                }
            } else {
                $inputCompleted = $false
                try {
                    $inputCompleted = $inputTask.Wait($remainingMilliseconds)
                } catch {
                    $inputCompleted = $true
                    $inputWriteFailed = $true
                }
                if (-not $inputCompleted) {
                    $timedOut = $true
                    $nativeWorker.CloseInput()
                    if (-not $treeTerminationConfirmed) {
                        $termination = Stop-WorkerProcessTree `
                            -Process $process `
                            -JobHandle $jobHandle `
                            -JobAssigned $jobAssigned
                        $terminationSucceeded = $termination.processTerminated
                        $treeTerminationConfirmed = $termination.treeTerminationConfirmed
                    }
                } elseif ($inputTask.IsFaulted -or $inputTask.IsCanceled) {
                    $inputWriteFailed = $true
                }
            }
        }

        $streamDrainDeadline = [DateTime]::UtcNow.AddMilliseconds(5000)
        $stdoutRead = Get-TaskTextWithin -Task $stdoutTask -WaitMilliseconds 5000
        $remainingDrainMilliseconds = [int][Math]::Floor(
            ($streamDrainDeadline - [DateTime]::UtcNow).TotalMilliseconds
        )
        $stderrRead = Get-TaskTextWithin -Task $stderrTask -WaitMilliseconds ([Math]::Max(1, $remainingDrainMilliseconds))
        $readTimedOut = -not ($stdoutRead.completed -and $stderrRead.completed)
        if ($stdoutCapture.LimitExceeded -or $stderrCapture.LimitExceeded) {
            $outputLimitExceeded = $true
            if (-not $treeTerminationConfirmed) {
                $nativeWorker.CloseInput()
                $termination = Stop-WorkerProcessTree `
                    -Process $process `
                    -JobHandle $jobHandle `
                    -JobAssigned $jobAssigned
                $terminationSucceeded = $termination.processTerminated
                $treeTerminationConfirmed = $termination.treeTerminationConfirmed
            }
        }
        $exitCode = if ($outputLimitExceeded) { 126 } elseif ($timedOut) { 124 } elseif ($inputWriteFailed) { 125 } elseif ($readTimedOut) { 125 } else { $process.ExitCode }
        $standardOutput = if ($outputLimitExceeded) { '' } else { $stdoutRead.text.TrimEnd() }
        $standardError = if ($outputLimitExceeded) { '' } else { $stderrRead.text.TrimEnd() }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = $standardOutput
            StandardOutput = $standardOutput
            StandardError = $standardError
            TimedOut = $timedOut
            ReadTimedOut = $readTimedOut
            InputWriteFailed = $inputWriteFailed
            OutputLimitExceeded = $outputLimitExceeded
            FailureKindOverride = if ($inputWriteFailed) { 'wrapper_error' } else { $null }
            DurationMs = [int64]$stopwatch.ElapsedMilliseconds
            TerminationSucceeded = $terminationSucceeded
            ContainmentApplied = $jobAssigned
            TreeTerminationConfirmed = $treeTerminationConfirmed
        }
    } finally {
        $stopwatch.Stop()
        if ($jobAssigned -and -not $treeTerminationConfirmed) {
            [void](Stop-WorkerJobObject -JobHandle $jobHandle)
        }
        Close-WorkerJobObject -JobHandle $jobHandle
        if ($null -ne $nativeWorker) {
            $nativeWorker.Dispose()
        } elseif ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-WorkerFailureKind {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $override = Get-AiwProperty -Object $Result -Name 'FailureKindOverride' -DefaultValue $null
    if (-not [string]::IsNullOrWhiteSpace([string]$override)) {
        return [string]$override
    }
    if ((Get-AiwProperty -Object $Result -Name 'OutputLimitExceeded' -DefaultValue $false)) {
        return 'output_limit'
    }
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
    $diagnostics = Get-PublicWorkerDiagnostics -Result $Result
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

function Invoke-AiwPlannedWorker {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $environmentPreviousValues = @{}
    $result = $null
    $artifactDirectory = $null
    $plannedArguments = @($Plan.arguments)
    $cleanupFailed = $false
    $executionAttempted = $false
    try {
        $artifactProperty = $Plan.PSObject.Properties['artifact']
        if ($null -ne $artifactProperty -and $null -ne $artifactProperty.Value) {
            $artifactPlan = $artifactProperty.Value
            $workOrder = switch ([string]$artifactPlan.kind) {
                'antigravity-work-order' {
                    New-EphemeralGoogleWorkOrder -Text ([string]$artifactPlan.promptText)
                    break
                }
                'minimax-messages' {
                    New-EphemeralMiniMaxMessages -Text ([string]$artifactPlan.promptText)
                    break
                }
                default {
                    throw 'The execution plan requested an unsupported controlled artifact.'
                }
            }
            $artifactDirectory = [string]$workOrder.directory
            $fileArgumentIndex = [int]$artifactPlan.fileArgumentIndex
            if ($fileArgumentIndex -lt 0 -or
                $fileArgumentIndex -ge $plannedArguments.Count -or
                [string]::IsNullOrWhiteSpace([string]$artifactPlan.fileArgumentFormat)) {
                throw 'The controlled artifact file binding is invalid.'
            }
            $plannedArguments[$fileArgumentIndex] = (
                [string]$artifactPlan.fileArgumentFormat -f [string]$workOrder.path
            )
            $directoryIndexProperty = $artifactPlan.PSObject.Properties['directoryArgumentIndex']
            if ($null -ne $directoryIndexProperty -and
                $null -ne $directoryIndexProperty.Value) {
                $directoryArgumentIndex = [int]$directoryIndexProperty.Value
                if ($directoryArgumentIndex -lt 0 -or
                    $directoryArgumentIndex -ge $plannedArguments.Count) {
                    throw 'The controlled artifact directory binding is invalid.'
                }
                $plannedArguments[$directoryArgumentIndex] = $artifactDirectory
            }
        }
        foreach ($property in $Plan.environmentOverlay.PSObject.Properties) {
            $environmentPreviousValues[$property.Name] = [Environment]::GetEnvironmentVariable($property.Name)
            Set-Item -LiteralPath ('Env:{0}' -f $property.Name) -Value ([string]$property.Value)
        }
        $executionAttempted = $true
        $result = Invoke-NativeWorker `
            -FilePath $Plan.filePath `
            -Arguments $plannedArguments `
            -Directory $Plan.workingDirectory `
            -ProcessTimeoutSeconds $TimeoutSeconds `
            -ProcessTimeoutMilliseconds $TimeoutMilliseconds `
            -StandardInputText $Plan.standardInputText `
            -AllowBatchWorker:$Plan.allowBatchWorker
    } catch {
        $message = [string]$_.Exception.Message
        $failureKind = if ($message -match '(?i)(failed to start|executable.*not found)') {
            'process_start_failed'
        } else {
            'wrapper_error'
        }
        $result = [pscustomobject]@{
            ExitCode = 126
            Output = ''
            StandardOutput = ''
            StandardError = 'Worker execution could not be started safely.'
            TimedOut = $false
            ReadTimedOut = $false
            OutputLimitExceeded = $false
            DurationMs = 0
            TerminationSucceeded = $false
            ContainmentApplied = $false
            TreeTerminationConfirmed = $false
            FailureKindOverride = $failureKind
        }
    } finally {
        foreach ($name in $environmentPreviousValues.Keys) {
            try {
                Restore-EnvironmentVariable -Name $name -PreviousValue $environmentPreviousValues[$name]
            } catch {
                $cleanupFailed = $true
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($artifactDirectory)) {
            try {
                Remove-AiwTemporaryDirectory -Path $artifactDirectory
            } catch {
                $cleanupFailed = $true
            }
        }
        if ($cleanupFailed) {
            if ($null -eq $result) {
                $result = [pscustomobject]@{
                    ExitCode = 126
                    Output = ''
                    StandardOutput = ''
                    StandardError = ''
                    TimedOut = $false
                    ReadTimedOut = $false
                    OutputLimitExceeded = $false
                    DurationMs = 0
                    TerminationSucceeded = $false
                    ContainmentApplied = $false
                    TreeTerminationConfirmed = $false
                }
            }
            $originalExitCode = [int]$result.ExitCode
            $result.ExitCode = 126
            $result | Add-Member `
                -MemberType NoteProperty `
                -Name ChildExitCodeOverride `
                -Value $originalExitCode `
                -Force
            $result | Add-Member `
                -MemberType NoteProperty `
                -Name FailureKindOverride `
                -Value 'wrapper_error' `
                -Force
            $result | Add-Member `
                -MemberType NoteProperty `
                -Name FailurePhaseOverride `
                -Value 'cleanup' `
                -Force
            $result | Add-Member `
                -MemberType NoteProperty `
                -Name CleanupFailed `
                -Value $true `
                -Force
            $result | Add-Member `
                -MemberType NoteProperty `
                -Name PublicDiagnosticsOverride `
                -Value $(if ($executionAttempted) {
                    'Worker cleanup failed after the execution phase.'
                } else {
                    'Worker cleanup failed before execution could begin.'
                }) `
                -Force
        }
    }
    return $result
}

function Test-AiwFallbackAllowed {
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$NativeResult,
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][int]$AttemptCount,
        [Parameter(Mandatory)][int64]$RemainingMilliseconds
    )

    if ($Policy.selectorKind -eq 'worker' -or
        [bool]$Request.noFallback -or
        [string]$Request.mode -eq 'write' -or
        $AttemptCount -ge [int]$Policy.maxAttempts -or
        $RemainingMilliseconds -le 0) {
        return $false
    }
    if (@(
        'permission_denied',
        'config_invalid',
        'capability_denied',
        'launcher_unsafe',
        'wrapper_error',
        'process_start_failed',
        'policy_denied',
        'stream_drain_timeout',
        'output_limit'
    ) -contains $FailureKind) {
        return $false
    }
    if ($FailureKind -eq 'timeout' -and -not [bool](Get-AiwProperty `
        -Object $NativeResult `
        -Name 'TreeTerminationConfirmed' `
        -DefaultValue $false)) {
        return $false
    }
    return @($Policy.on) -contains $FailureKind
}

function New-AiwPublicRunFailure {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('preflight', 'wrapper')][string]$Phase = 'preflight',
        [object[]]$Errors = @()
    )

    return [pscustomobject]@{
        schemaVersion = 2
        productVersion = $script:AiwVersion
        ok = $false
        command = 'run'
        request = $Request
        selection = $null
        exitCode = 2
        timedOut = $false
        readTimedOut = $false
        outputLimitExceeded = $false
        cleanupFailed = $false
        terminationSucceeded = $false
        containmentApplied = $false
        treeTerminationConfirmed = $false
        durationMs = 0
        failureKind = $FailureKind
        skipped = @()
        attempts = @()
        output = ''
        error = [pscustomobject]@{
            code = $Code
            phase = $Phase
            message = $Message
        }
        errors = @($Errors)
        diagnostics = $null
        warnings = @()
    }
}

function Write-AiwPublicRunFailure {
    param([Parameter(Mandatory)][object]$Result)

    if ($Json) {
        ConvertTo-Json -InputObject $Result -Depth 20
    } else {
        Write-Error ([string]$Result.error.message) -ErrorAction Continue
    }
    exit [int]$Result.exitCode
}

if ($MyInvocation.InvocationName -ne '.' -and (
    $Command -in @('catalog', 'config', 'run') -or
    ($OutputSchema -eq 2 -and $Command -in @('status', 'doctor'))
)) {
    try {
        $publicRunRequest = [pscustomobject]@{
            worker = $Worker
            profile = $Profile
            route = $Route
            mode = $Mode
            requiredCapabilities = @($RequireCapability)
        }
        if ($Command -eq 'run' -and (
            -not [string]::IsNullOrWhiteSpace($Model) -or
            -not [string]::IsNullOrWhiteSpace($GoogleModel) -or
            -not [string]::IsNullOrWhiteSpace($AgentModel)
        )) {
            $modelOverrideFailure = New-AiwPublicRunFailure `
                -Request $publicRunRequest `
                -Code 'MODEL_OVERRIDE_FORBIDDEN' `
                -FailureKind 'invalid_request' `
                -Message 'Schema v2 worker models are fixed by configuration.'
            Write-AiwPublicRunFailure -Result $modelOverrideFailure
        }
        if ($Command -eq 'run' -and $MaxPromptBytes -gt 1048576) {
            $promptLimitFailure = New-AiwPublicRunFailure `
                -Request $publicRunRequest `
                -Code 'PROMPT_INVALID' `
                -FailureKind 'invalid_request' `
                -Message 'Schema v2 work orders cannot exceed one MiB.'
            Write-AiwPublicRunFailure -Result $promptLimitFailure
        }
        $coreConfigPath = if ($Command -eq 'catalog') { $null } else { Resolve-AiwCoreConfigPath }
        $coreRequest = if ($Command -eq 'catalog') {
            [pscustomobject]@{
                command = 'catalog'
            }
        } elseif ($Command -in @('status', 'doctor')) {
            [pscustomobject]@{
                command = 'inventory'
                configPath = [string]$coreConfigPath
                outputCommand = $Command
            }
        } elseif ($Command -eq 'config') {
            if ($Action -eq 'validate') {
                [pscustomobject]@{
                    command = 'config.validate'
                    configPath = [string]$coreConfigPath
                }
            } elseif ($Action -eq 'migrate') {
                [pscustomobject]@{
                    command = 'config.migrate'
                    configPath = [string]$coreConfigPath
                    destinationPath = $Destination
                }
            } else {
                throw 'The config command requires -Action validate or -Action migrate.'
            }
        } else {
            try {
                $resolvedDirectory = Resolve-WorkerDirectory -Path $WorkingDirectory
            } catch {
                $workDirectoryFailure = New-AiwPublicRunFailure `
                    -Request $publicRunRequest `
                    -Code 'WORKDIR_INVALID' `
                    -FailureKind 'invalid_request' `
                    -Message 'The requested working directory is invalid.'
                Write-AiwPublicRunFailure -Result $workDirectoryFailure
            }
            try {
                $promptText = Resolve-PromptText -InlinePrompt $Prompt -FilePath $PromptFile
            } catch {
                $promptFailure = New-AiwPublicRunFailure `
                    -Request $publicRunRequest `
                    -Code 'PROMPT_INVALID' `
                    -FailureKind 'invalid_request' `
                    -Message 'The work order is missing, invalid, or exceeds the configured limit.'
                Write-AiwPublicRunFailure -Result $promptFailure
            }
            if ([string]::IsNullOrWhiteSpace($promptText)) {
                $promptFailure = New-AiwPublicRunFailure `
                    -Request $publicRunRequest `
                    -Code 'PROMPT_INVALID' `
                    -FailureKind 'invalid_request' `
                    -Message 'The work order is missing, invalid, or exceeds the configured limit.'
                Write-AiwPublicRunFailure -Result $promptFailure
            }
            [pscustomobject]@{
                command = 'run.plan'
                configPath = [string]$coreConfigPath
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
        $runStopwatch = if ($Command -eq 'run') {
            [System.Diagnostics.Stopwatch]::StartNew()
        } else {
            $null
        }
        $coreResult = Invoke-AiwCore -Request $coreRequest
        $coreResult | Add-Member `
            -MemberType NoteProperty `
            -Name productVersion `
            -Value $script:AiwVersion `
            -Force
        if ($Command -eq 'run' -and $coreResult.ok) {
            $totalTimeoutMilliseconds = [int64]$TimeoutSeconds * 1000
            $attempts = @()
            $allSkipped = @($coreResult.skipped)
            $excludedWorkers = @()
            $currentCoreResult = $coreResult
            $nativeResult = $null
            $failureKind = $null
            while ($attempts.Count -lt [int]$coreResult.fallbackPolicy.maxAttempts) {
                $remainingMilliseconds = $totalTimeoutMilliseconds - $runStopwatch.ElapsedMilliseconds
                if ($remainingMilliseconds -le 0) {
                    break
                }
                $boundedRemainingMilliseconds = [int][Math]::Min(
                    [int]::MaxValue,
                    $remainingMilliseconds
                )
                $nativeResult = Invoke-AiwPlannedWorker `
                    -Plan $currentCoreResult.plan `
                    -TimeoutSeconds $TimeoutSeconds `
                    -TimeoutMilliseconds $boundedRemainingMilliseconds
                $failureKind = Get-WorkerFailureKind -Result $nativeResult
                $attempts += [pscustomobject]@{
                    worker = $currentCoreResult.selection.worker
                    adapter = $currentCoreResult.selection.adapter
                    model = $currentCoreResult.selection.model
                    childExitCode = (Get-AiwProperty `
                        -Object $nativeResult `
                        -Name 'ChildExitCodeOverride' `
                        -DefaultValue $nativeResult.ExitCode)
                    failureKind = $failureKind
                    timedOut = $nativeResult.TimedOut
                    readTimedOut = $nativeResult.ReadTimedOut
                    outputLimitExceeded = (Get-AiwProperty -Object $nativeResult -Name 'OutputLimitExceeded' -DefaultValue $false)
                    terminationSucceeded = $nativeResult.TerminationSucceeded
                    containmentApplied = (Get-AiwProperty -Object $nativeResult -Name 'ContainmentApplied' -DefaultValue $false)
                    treeTerminationConfirmed = (Get-AiwProperty -Object $nativeResult -Name 'TreeTerminationConfirmed' -DefaultValue $false)
                    cleanupFailed = (Get-AiwProperty -Object $nativeResult -Name 'CleanupFailed' -DefaultValue $false)
                    durationMs = $nativeResult.DurationMs
                    diagnostics = Get-PublicWorkerDiagnostics -Result $nativeResult
                }
                if ($nativeResult.ExitCode -eq 0) {
                    break
                }

                $remainingMilliseconds = $totalTimeoutMilliseconds - $runStopwatch.ElapsedMilliseconds
                if (-not (Test-AiwFallbackAllowed `
                    -Policy $coreResult.fallbackPolicy `
                    -Request $coreRequest `
                    -NativeResult $nativeResult `
                    -FailureKind $failureKind `
                    -AttemptCount $attempts.Count `
                    -RemainingMilliseconds $remainingMilliseconds)) {
                    break
                }

                $excludedWorkers += [string]$currentCoreResult.selection.worker
                $coreRequest | Add-Member `
                    -MemberType NoteProperty `
                    -Name excludedWorkers `
                    -Value @($excludedWorkers) `
                    -Force
                $nextCoreResult = Invoke-AiwCore -Request $coreRequest
                if (-not $nextCoreResult.ok) {
                    break
                }
                foreach ($skip in @($nextCoreResult.skipped)) {
                    $alreadyReported = @(
                        $allSkipped |
                            Where-Object {
                                $_.worker -eq $skip.worker -and
                                $_.reason -eq $skip.reason
                            }
                    ).Count -gt 0
                    if (-not $alreadyReported) {
                        $allSkipped += $skip
                    }
                }
                $currentCoreResult = $nextCoreResult
            }
            $runStopwatch.Stop()
            if ($null -eq $nativeResult) {
                $nativeResult = [pscustomobject]@{
                    ExitCode = 124
                    StandardOutput = ''
                    StandardError = ''
                    TimedOut = $true
                    ReadTimedOut = $false
                    OutputLimitExceeded = $false
                    DurationMs = [int64]$runStopwatch.ElapsedMilliseconds
                    TerminationSucceeded = $true
                    ContainmentApplied = $true
                    TreeTerminationConfirmed = $true
                }
                $failureKind = 'timeout'
            }

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
                productVersion = $script:AiwVersion
                ok = ($nativeResult.ExitCode -eq 0)
                command = 'run'
                request = $coreResult.request
                selection = $currentCoreResult.selection
                exitCode = $publicExitCode
                timedOut = $nativeResult.TimedOut
                readTimedOut = $nativeResult.ReadTimedOut
                outputLimitExceeded = (Get-AiwProperty -Object $nativeResult -Name 'OutputLimitExceeded' -DefaultValue $false)
                cleanupFailed = (Get-AiwProperty -Object $nativeResult -Name 'CleanupFailed' -DefaultValue $false)
                terminationSucceeded = $nativeResult.TerminationSucceeded
                containmentApplied = (Get-AiwProperty -Object $nativeResult -Name 'ContainmentApplied' -DefaultValue $false)
                treeTerminationConfirmed = (Get-AiwProperty -Object $nativeResult -Name 'TreeTerminationConfirmed' -DefaultValue $false)
                durationMs = [int64]$runStopwatch.ElapsedMilliseconds
                failureKind = $failureKind
                skipped = @($allSkipped)
                attempts = @($attempts)
                output = Convert-OutputValue -Text ([string]$nativeResult.StandardOutput)
                error = if ($nativeResult.ExitCode -eq 0) {
                    $null
                } else {
                    [pscustomobject]@{
                        code = $failureKind.ToUpperInvariant()
                        phase = (Get-AiwProperty `
                            -Object $nativeResult `
                            -Name 'FailurePhaseOverride' `
                            -DefaultValue 'execution')
                        message = if ([bool](Get-AiwProperty `
                            -Object $nativeResult `
                            -Name 'CleanupFailed' `
                            -DefaultValue $false)) {
                            'Worker cleanup failed.'
                        } else {
                            'Worker execution failed.'
                        }
                    }
                }
                diagnostics = Get-PublicWorkerDiagnostics -Result $nativeResult
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
                if ($Action -eq 'migrate') {
                    Write-Output ('Configuration migrated to {0}.' -f $coreResult.destinationPath)
                } else {
                    Write-Output ('Configuration is valid (schema {0}).' -f $coreResult.configSchemaVersion)
                }
            } else {
                $coreResult.errors | Format-Table -AutoSize
            }
        } elseif ($Command -eq 'catalog') {
            $coreResult.adapters |
                Select-Object id, displayName, promptTransport, @{Name = 'capabilities'; Expression = { $_.capabilities -join ', ' }} |
                Format-Table -AutoSize
        } elseif ($Command -in @('status', 'doctor')) {
            $coreResult.workers |
                Select-Object worker, adapter, available, enabled, modelPinned, provenance, path |
                Format-Table -AutoSize
        }
        exit [int]$coreResult.exitCode
    } catch {
        if ($Command -eq 'run') {
            $wrapperFailure = New-AiwPublicRunFailure `
                -Request $publicRunRequest `
                -Code 'WRAPPER_ERROR' `
                -FailureKind 'wrapper_error' `
                -Message 'The wrapper failed before worker execution.' `
                -Phase 'wrapper'
            Write-AiwPublicRunFailure -Result $wrapperFailure
        }
        if ($Json) {
            [pscustomobject]@{
                schemaVersion = 2
                productVersion = $script:AiwVersion
                ok = $false
                command = $Command
                action = if ($Command -eq 'config') { $Action } else { $null }
                exitCode = 1
                failureKind = 'wrapper_error'
                errors = @()
                error = [pscustomobject]@{
                    code = 'WRAPPER_ERROR'
                    message = 'Core request failed.'
                }
                diagnostics = Get-SanitizedDiagnostics -Text $_.Exception.Message
                warnings = @()
            } | ConvertTo-Json -Depth 20
        } else {
            $safeDiagnostic = Get-SanitizedDiagnostics -Text $_.Exception.Message
            Write-Error $safeDiagnostic -ErrorAction Continue
        }
        exit 1
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
