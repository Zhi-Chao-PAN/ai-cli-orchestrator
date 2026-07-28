Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AiwAdapterCatalog {
    return @(
        [pscustomobject]@{
            id = 'claude-code/v1'
            displayName = 'Claude Code'
            capabilities = @('text.reason', 'workspace.read', 'workspace.write')
            promptTransport = 'stdin'
            launcherExtensions = @('.exe', '.ps1')
        },
        [pscustomobject]@{
            id = 'antigravity/v1'
            displayName = 'Google Antigravity CLI'
            capabilities = @('text.reason', 'context.long', 'workspace.read', 'workspace.write')
            promptTransport = 'ephemeral-file'
            launcherExtensions = @('.exe', '.ps1')
        },
        [pscustomobject]@{
            id = 'minimax-cli/v1'
            displayName = 'MiniMax CLI'
            capabilities = @('text.reason', 'quota.read')
            promptTransport = 'ephemeral-file'
            launcherExtensions = @('.exe', '.ps1', '.cmd')
        }
    )
}

function Read-AiwConfigDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Configuration file does not exist.'
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolvedPath
    if ($item.Length -gt 1048576) {
        throw 'Configuration file exceeds the 1048576-byte limit.'
    }

    $reader = New-Object System.IO.StreamReader(
        $resolvedPath,
        (New-Object System.Text.UTF8Encoding($false, $true)),
        $true
    )
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    try {
        $document = $text | ConvertFrom-Json
    } catch {
        throw 'Configuration is not valid JSON.'
    }
    return [pscustomobject]@{
        path = $resolvedPath
        document = $document
    }
}

function New-AiwConfigValidationResult {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $loaded = Read-AiwConfigDocument -Path $Path
    $schemaProperty = $loaded.document.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or
        $schemaProperty.Value -isnot [int] -or
        [int]$schemaProperty.Value -ne 2) {
        throw 'Configuration schemaVersion must be the integer 2.'
    }

    $allowedTopLevelFields = @(
        'schemaVersion',
        'defaultRoute',
        'defaultProfile',
        'workers',
        'profiles',
        'routes'
    )
    $forbiddenFieldNames = @(
        'command',
        'args',
        'arguments',
        'template',
        'script',
        'shell',
        'hook',
        'env'
    )
    $errors = @()
    foreach ($property in $loaded.document.PSObject.Properties) {
        if ($allowedTopLevelFields -contains $property.Name) {
            continue
        }
        $code = if ($forbiddenFieldNames -contains $property.Name.ToLowerInvariant()) {
            'FIELD_FORBIDDEN'
        } else {
            'FIELD_UNKNOWN'
        }
        $errors += [pscustomobject]@{
            code = $code
            path = '$.' + $property.Name
            message = if ($code -eq 'FIELD_FORBIDDEN') {
                'Executable configuration fields are forbidden.'
            } else {
                'Configuration field is not supported.'
            }
        }
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $false
            command = 'config'
            action = 'validate'
            configSchemaVersion = 2
            configPath = $loaded.path
            exitCode = 2
            failureKind = 'config_invalid'
            errors = @($errors | Sort-Object path, code)
            error = [pscustomobject]@{
                code = 'CONFIG_INVALID'
                message = 'Configuration validation failed.'
            }
            diagnostics = $null
            warnings = @()
        }
    }

    return [pscustomobject]@{
        schemaVersion = 2
        ok = $true
        command = 'config'
        action = 'validate'
        configSchemaVersion = 2
        configPath = $loaded.path
        exitCode = 0
        failureKind = $null
        errors = @()
        error = $null
        diagnostics = $null
        warnings = @()
    }
}

function Invoke-AiwCore {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [psobject]$Request
    )

    $commandProperty = $Request.PSObject.Properties['command']
    if ($null -eq $commandProperty -or
        [string]::IsNullOrWhiteSpace([string]$commandProperty.Value)) {
        throw 'Core request is missing command.'
    }

    switch ([string]$commandProperty.Value) {
        'catalog' {
            return [pscustomobject]@{
                schemaVersion = 2
                ok = $true
                command = 'catalog'
                exitCode = 0
                adapters = @(Get-AiwAdapterCatalog)
                error = $null
                diagnostics = $null
                warnings = @()
            }
        }
        'config.validate' {
            $pathProperty = $Request.PSObject.Properties['configPath']
            if ($null -eq $pathProperty) {
                throw 'Core config request is missing configPath.'
            }
            return New-AiwConfigValidationResult -Path ([string]$pathProperty.Value)
        }
        default {
            throw ('Unsupported core command: {0}' -f $commandProperty.Value)
        }
    }
}

Export-ModuleMember -Function Invoke-AiwCore
