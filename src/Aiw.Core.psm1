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
        default {
            throw ('Unsupported core command: {0}' -f $commandProperty.Value)
        }
    }
}

Export-ModuleMember -Function Invoke-AiwCore
