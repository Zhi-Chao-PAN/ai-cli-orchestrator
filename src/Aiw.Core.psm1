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

function Test-AiwForbiddenConfigFieldName {
    param([Parameter(Mandatory)][string]$Name)

    return @(
        'command',
        'args',
        'arguments',
        'template',
        'script',
        'shell',
        'hook',
        'env'
    ) -contains $Name.ToLowerInvariant()
}

function Test-AiwSecretConfigFieldName {
    param([Parameter(Mandatory)][string]$Name)

    $normalizedName = ($Name -replace '[-_]', '').ToLowerInvariant()
    return @(
        'key',
        'apikey',
        'accesskey',
        'secret',
        'apisecret',
        'secretkey',
        'token',
        'accesstoken',
        'authtoken',
        'refreshtoken',
        'sessiontoken',
        'clientsecret',
        'password',
        'credential',
        'credentials',
        'authorization',
        'cookie',
        'setcookie',
        'bearer'
    ) -contains $normalizedName
}

function Test-AiwIntegerValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $false
    }
    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    return @(
        [System.TypeCode]::SByte,
        [System.TypeCode]::Byte,
        [System.TypeCode]::Int16,
        [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32,
        [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64,
        [System.TypeCode]::UInt64
    ) -contains $typeCode
}

function Get-AiwUnsafeFieldErrors {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Depth = 0
    )

    if ($Depth -gt 20) {
        Write-Output ([pscustomobject]@{
            code = 'CONFIG_LIMIT_EXCEEDED'
            path = $Path
            message = 'Configuration nesting exceeds the supported limit.'
        })
        return
    }
    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Array]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Get-AiwUnsafeFieldErrors -Value $Value[$index] -Path ('{0}[{1}]' -f $Path, $index) -Depth ($Depth + 1)
        }
        return
    }
    if ($Value -isnot [pscustomobject]) {
        return
    }

    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = $Path + '.' + $property.Name
        if (Test-AiwSecretConfigFieldName -Name $property.Name) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_SECRET_FORBIDDEN'
                path = $Path + '.<redacted>'
                message = 'Credential fields are forbidden in AIW configuration.'
            })
            continue
        }
        if (Test-AiwForbiddenConfigFieldName -Name $property.Name) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_FORBIDDEN'
                path = $propertyPath
                message = 'Executable configuration fields are forbidden.'
            })
            continue
        }
        Get-AiwUnsafeFieldErrors -Value $property.Value -Path $propertyPath -Depth ($Depth + 1)
    }
}

function Get-AiwAdapterSettingValidationErrors {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [AllowNull()][object]$Settings,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $Settings) {
        $Settings = [pscustomobject]@{}
    }
    if ($Settings -isnot [pscustomobject]) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = $Path
            message = 'Adapter settings must be a JSON object.'
        })
        return
    }

    $allowedFields = switch ($Adapter.id) {
        'claude-code/v1' { @('configDirectory') }
        'antigravity/v1' { @() }
        'minimax-cli/v1' { @('region', 'configDirectory') }
        default { @() }
    }
    foreach ($property in $Settings.PSObject.Properties) {
        if ($allowedFields -contains $property.Name -or
            (Test-AiwSecretConfigFieldName -Name $property.Name) -or
            (Test-AiwForbiddenConfigFieldName -Name $property.Name)) {
            continue
        }
        Write-Output ([pscustomobject]@{
            code = 'FIELD_UNKNOWN'
            path = $Path + '.' + $property.Name
            message = 'Adapter setting is not supported.'
        })
    }

    $configDirectoryProperty = $Settings.PSObject.Properties['configDirectory']
    if ($null -ne $configDirectoryProperty -and
        ($configDirectoryProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$configDirectoryProperty.Value))) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = $Path + '.configDirectory'
            message = 'Config directory must be a non-empty string.'
        })
    }

    if ($Adapter.id -eq 'minimax-cli/v1') {
        $regionProperty = $Settings.PSObject.Properties['region']
        if ($null -eq $regionProperty) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_REQUIRED'
                path = $Path + '.region'
                message = 'MiniMax region is required.'
            })
        } elseif ($regionProperty.Value -isnot [string] -or
            @('cn', 'global') -notcontains [string]$regionProperty.Value) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_VALUE_INVALID'
                path = $Path + '.region'
                message = 'MiniMax region is not supported.'
            })
        }
    }
}

function Get-AiwAdapterDescriptor {
    param([Parameter(Mandatory)][string]$Id)

    return @(Get-AiwAdapterCatalog | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

function New-AiwMiniMaxMessageArtifact {
    param([Parameter(Mandatory)][string]$PromptText)

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('aiw-minimax-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
    $path = Join-Path $directory 'messages.json'
    try {
        $messages = @(
            [pscustomobject]@{
                role = 'user'
                content = $PromptText
            }
        )
        $json = ConvertTo-Json -InputObject $messages -Depth 5 -Compress
        [System.IO.File]::WriteAllText(
            $path,
            $json,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } catch {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        throw
    }
    return [pscustomobject]@{
        directory = $directory
        path = $path
    }
}

function New-AiwAntigravityWorkOrderArtifact {
    param([Parameter(Mandatory)][string]$PromptText)

    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('aiw-google-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
    $path = Join-Path $directory 'work-order.md'
    try {
        [System.IO.File]::WriteAllText(
            $path,
            $PromptText,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } catch {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        throw
    }
    return [pscustomobject]@{
        directory = $directory
        path = $path
    }
}

function Get-AiwWorkerValidationErrors {
    param(
        [AllowNull()]
        [object]$Workers
    )

    if ($null -eq $Workers -or $Workers -isnot [pscustomobject]) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = '$.workers'
            message = 'Workers must be a JSON object.'
        })
        return
    }
    if (@($Workers.PSObject.Properties).Count -gt 128) {
        Write-Output ([pscustomobject]@{
            code = 'CONFIG_LIMIT_EXCEEDED'
            path = '$.workers'
            message = 'Worker count exceeds the supported limit.'
        })
        return
    }

    $allowedWorkerFields = @('adapter', 'enabled', 'path', 'model', 'capabilities', 'settings')
    foreach ($workerProperty in $Workers.PSObject.Properties) {
        $workerId = $workerProperty.Name
        $workerPath = '$.workers.' + $workerId
        if ($workerId -notmatch '^[a-z][a-z0-9._-]{0,63}$') {
            Write-Output ([pscustomobject]@{
                code = 'ID_INVALID'
                path = $workerPath
                message = 'Worker ID is invalid.'
            })
            continue
        }
        $worker = $workerProperty.Value
        if ($worker -isnot [pscustomobject]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $workerPath
                message = 'Worker definition must be a JSON object.'
            })
            continue
        }
        foreach ($property in $worker.PSObject.Properties) {
            if ($allowedWorkerFields -notcontains $property.Name) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_UNKNOWN'
                    path = $workerPath + '.' + $property.Name
                    message = 'Worker field is not supported.'
                })
            }
        }


        $enabledProperty = $worker.PSObject.Properties['enabled']
        if ($null -ne $enabledProperty -and $enabledProperty.Value -isnot [bool]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $workerPath + '.enabled'
                message = 'Worker enabled must be a boolean.'
            })
        }
        $pathProperty = $worker.PSObject.Properties['path']
        if ($null -ne $pathProperty -and $null -ne $pathProperty.Value -and
            ($pathProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$pathProperty.Value))) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $workerPath + '.path'
                message = 'Worker path must be null or a non-empty string.'
            })
        }
        $modelProperty = $worker.PSObject.Properties['model']
        if ($null -ne $modelProperty -and $null -ne $modelProperty.Value -and
            $modelProperty.Value -isnot [string]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $workerPath + '.model'
                message = 'Worker model must be null or a string.'
            })
        } elseif ($null -ne $modelProperty -and $modelProperty.Value -is [string] -and
            ([string]::IsNullOrWhiteSpace([string]$modelProperty.Value) -or
            ([string]$modelProperty.Value).Length -gt 256 -or
            [string]$modelProperty.Value -match '[\x00-\x1F\x7F]')) {
            Write-Output ([pscustomobject]@{
                code = 'MODEL_INVALID'
                path = $workerPath + '.model'
                message = 'Worker model is invalid.'
            })
        }

        $adapterProperty = $worker.PSObject.Properties['adapter']
        if ($null -ne $adapterProperty -and $adapterProperty.Value -isnot [string]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $workerPath + '.adapter'
                message = 'Worker adapter must be a string.'
            })
            continue
        }
        $adapterId = if ($null -eq $adapterProperty) { $null } else { [string]$adapterProperty.Value }
        $adapter = if ([string]::IsNullOrWhiteSpace($adapterId)) {
            $null
        } else {
            Get-AiwAdapterDescriptor -Id $adapterId
        }
        if ($null -eq $adapter) {
            Write-Output ([pscustomobject]@{
                code = 'ADAPTER_UNKNOWN'
                path = $workerPath + '.adapter'
                message = 'Worker adapter is missing or unsupported.'
            })
            continue
        }

        if ($adapter.id -eq 'minimax-cli/v1') {
            if ($null -eq $modelProperty -or
                $modelProperty.Value -isnot [string] -or
                [string]$modelProperty.Value -notmatch '^[A-Za-z0-9._-]{1,128}$') {
                Write-Output ([pscustomobject]@{
                    code = 'MODEL_INVALID'
                    path = $workerPath + '.model'
                    message = 'MiniMax model is invalid.'
                })
            }
        }

        $settingsProperty = $worker.PSObject.Properties['settings']
        $settingsValue = if ($null -eq $settingsProperty) { $null } else { $settingsProperty.Value }
        Get-AiwAdapterSettingValidationErrors `
            -Adapter $adapter `
            -Settings $settingsValue `
            -Path ($workerPath + '.settings')

        $capabilitiesProperty = $worker.PSObject.Properties['capabilities']
        if ($null -ne $capabilitiesProperty -and $null -ne $capabilitiesProperty.Value) {
            if ($capabilitiesProperty.Value -isnot [System.Array]) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_TYPE_INVALID'
                    path = $workerPath + '.capabilities'
                    message = 'Worker capabilities must be an array.'
                })
                continue
            }
            $capabilities = @($capabilitiesProperty.Value)
            for ($index = 0; $index -lt $capabilities.Count; $index++) {
                $capability = [string]$capabilities[$index]
                if ($adapter.capabilities -notcontains $capability) {
                    Write-Output ([pscustomobject]@{
                        code = 'CAPABILITY_NOT_SUPPORTED'
                        path = ('{0}.capabilities[{1}]' -f $workerPath, $index)
                        message = 'Capability is not supported by the selected adapter.'
                    })
                }
            }
        }
    }
}

function Get-AiwFallbackValidationErrors {
    param(
        [AllowNull()][object]$Fallback,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $Fallback) {
        return
    }
    if ($Fallback -isnot [pscustomobject]) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = $Path
            message = 'Fallback policy must be a JSON object.'
        })
        return
    }

    foreach ($property in $Fallback.PSObject.Properties) {
        if (@('maxAttempts', 'on') -notcontains $property.Name) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_UNKNOWN'
                path = $Path + '.' + $property.Name
                message = 'Fallback field is not supported.'
            })
        }
    }

    $maxAttemptsProperty = $Fallback.PSObject.Properties['maxAttempts']
    if ($null -ne $maxAttemptsProperty) {
        if (-not (Test-AiwIntegerValue -Value $maxAttemptsProperty.Value)) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $Path + '.maxAttempts'
                message = 'Fallback maxAttempts must be an integer.'
            })
        } elseif ([int64]$maxAttemptsProperty.Value -lt 1 -or
            [int64]$maxAttemptsProperty.Value -gt 8) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_VALUE_INVALID'
                path = $Path + '.maxAttempts'
                message = 'Fallback maxAttempts is outside the supported range.'
            })
        }
    }

    $onProperty = $Fallback.PSObject.Properties['on']
    if ($null -ne $onProperty -and $null -ne $onProperty.Value) {
        if ($onProperty.Value -isnot [System.Array]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $Path + '.on'
                message = 'Fallback on must be an array.'
            })
            return
        }
        $allowedFailureKinds = @(
            'authentication',
            'quota_or_rate_limit',
            'process_exit',
            'timeout'
        )
        $seenFailureKinds = @{}
        $failureKinds = @($onProperty.Value)
        for ($index = 0; $index -lt $failureKinds.Count; $index++) {
            $failureKind = $failureKinds[$index]
            if ($failureKind -isnot [string] -or
                $allowedFailureKinds -notcontains [string]$failureKind) {
                Write-Output ([pscustomobject]@{
                    code = 'FALLBACK_KIND_FORBIDDEN'
                    path = ('{0}.on[{1}]' -f $Path, $index)
                    message = 'Fallback failure kind is not allowed.'
                })
                continue
            }
            if ($seenFailureKinds.ContainsKey([string]$failureKind)) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_VALUE_INVALID'
                    path = ('{0}.on[{1}]' -f $Path, $index)
                    message = 'Fallback failure kinds must be unique.'
                })
            } else {
                $seenFailureKinds[[string]$failureKind] = $true
            }
        }
    }
}

function Get-AiwProfileValidationErrors {
    param(
        [AllowNull()][object]$Profiles,
        [AllowNull()][object]$Workers
    )

    if ($null -eq $Profiles -or $Profiles -isnot [pscustomobject]) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = '$.profiles'
            message = 'Profiles must be a JSON object.'
        })
        return
    }
    if (@($Profiles.PSObject.Properties).Count -gt 64) {
        Write-Output ([pscustomobject]@{
            code = 'CONFIG_LIMIT_EXCEEDED'
            path = '$.profiles'
            message = 'Profile count exceeds the supported limit.'
        })
        return
    }

    foreach ($profileProperty in $Profiles.PSObject.Properties) {
        $profileId = $profileProperty.Name
        $profilePath = '$.profiles.' + $profileId
        if ($profileId -notmatch '^[a-z][a-z0-9._-]{0,63}$') {
            Write-Output ([pscustomobject]@{
                code = 'ID_INVALID'
                path = $profilePath
                message = 'Profile ID is invalid.'
            })
            continue
        }
        $profile = $profileProperty.Value
        if ($profile -isnot [pscustomobject]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $profilePath
                message = 'Profile definition must be a JSON object.'
            })
            continue
        }
        foreach ($property in $profile.PSObject.Properties) {
            if (@('workers', 'fallback') -notcontains $property.Name) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_UNKNOWN'
                    path = $profilePath + '.' + $property.Name
                    message = 'Profile field is not supported.'
                })
            }
        }
        $fallbackProperty = $profile.PSObject.Properties['fallback']
        if ($null -ne $fallbackProperty) {
            Get-AiwFallbackValidationErrors `
                -Fallback $fallbackProperty.Value `
                -Path ($profilePath + '.fallback')
        }
        $workerListProperty = $profile.PSObject.Properties['workers']
        if ($null -eq $workerListProperty -or
            $workerListProperty.Value -isnot [System.Array]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $profilePath + '.workers'
                message = 'Profile workers must be an array.'
            })
            continue
        }
        $workerList = @($workerListProperty.Value)
        if ($workerList.Count -eq 0) {
            Write-Output ([pscustomobject]@{
                code = 'PROFILE_EMPTY'
                path = $profilePath + '.workers'
                message = 'Profile must reference at least one worker.'
            })
            continue
        }
        for ($index = 0; $index -lt $workerList.Count; $index++) {
            $workerId = [string]$workerList[$index]
            if ($null -eq $Workers -or $null -eq $Workers.PSObject.Properties[$workerId]) {
                Write-Output ([pscustomobject]@{
                    code = 'WORKER_NOT_FOUND'
                    path = ('{0}.workers[{1}]' -f $profilePath, $index)
                    message = 'Profile references an unknown worker.'
                })
            }
        }
    }
}

function Get-AiwRouteValidationErrors {
    param(
        [AllowNull()][object]$Routes,
        [AllowNull()][object]$Profiles
    )

    if ($null -eq $Routes -or $Routes -isnot [pscustomobject]) {
        Write-Output ([pscustomobject]@{
            code = 'FIELD_TYPE_INVALID'
            path = '$.routes'
            message = 'Routes must be a JSON object.'
        })
        return
    }
    if (@($Routes.PSObject.Properties).Count -gt 64) {
        Write-Output ([pscustomobject]@{
            code = 'CONFIG_LIMIT_EXCEEDED'
            path = '$.routes'
            message = 'Route count exceeds the supported limit.'
        })
        return
    }

    $knownCapabilities = @(
        Get-AiwAdapterCatalog |
            ForEach-Object { $_.capabilities } |
            Select-Object -Unique
    )
    foreach ($routeProperty in $Routes.PSObject.Properties) {
        $routeId = $routeProperty.Name
        $routePath = '$.routes.' + $routeId
        if ($routeId -notmatch '^[a-z][a-z0-9._-]{0,63}$') {
            Write-Output ([pscustomobject]@{
                code = 'ID_INVALID'
                path = $routePath
                message = 'Route ID is invalid.'
            })
            continue
        }
        $route = $routeProperty.Value
        if ($route -isnot [pscustomobject]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = $routePath
                message = 'Route definition must be a JSON object.'
            })
            continue
        }
        foreach ($property in $route.PSObject.Properties) {
            if (@('profile', 'requiredCapabilities', 'defaultMode', 'allowedModes') -notcontains $property.Name) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_UNKNOWN'
                    path = $routePath + '.' + $property.Name
                    message = 'Route field is not supported.'
                })
            }
        }
        $profileProperty = $route.PSObject.Properties['profile']
        $profileId = if ($null -eq $profileProperty) { $null } else { [string]$profileProperty.Value }
        if ([string]::IsNullOrWhiteSpace($profileId) -or
            $null -eq $Profiles -or
            $null -eq $Profiles.PSObject.Properties[$profileId]) {
            Write-Output ([pscustomobject]@{
                code = 'PROFILE_NOT_FOUND'
                path = $routePath + '.profile'
                message = 'Route references an unknown profile.'
            })
        }
        $defaultModeProperty = $route.PSObject.Properties['defaultMode']
        if ($null -ne $defaultModeProperty -and [string]$defaultModeProperty.Value -ne 'read') {
            Write-Output ([pscustomobject]@{
                code = 'ROUTE_DEFAULT_WRITE_FORBIDDEN'
                path = $routePath + '.defaultMode'
                message = 'Routes can only default to read mode.'
            })
        }
        $capabilitiesProperty = $route.PSObject.Properties['requiredCapabilities']
        if ($null -ne $capabilitiesProperty -and $null -ne $capabilitiesProperty.Value) {
            if ($capabilitiesProperty.Value -isnot [System.Array]) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_TYPE_INVALID'
                    path = $routePath + '.requiredCapabilities'
                    message = 'Route capabilities must be an array.'
                })
            } else {
            $capabilities = @($capabilitiesProperty.Value)
            for ($index = 0; $index -lt $capabilities.Count; $index++) {
                if ($knownCapabilities -notcontains [string]$capabilities[$index]) {
                    Write-Output ([pscustomobject]@{
                        code = 'CAPABILITY_UNKNOWN'
                        path = ('{0}.requiredCapabilities[{1}]' -f $routePath, $index)
                        message = 'Route capability is not recognized.'
                    })
                }
            }
            }
        }
        $allowedModesProperty = $route.PSObject.Properties['allowedModes']
        if ($null -ne $allowedModesProperty -and $null -ne $allowedModesProperty.Value) {
            if ($allowedModesProperty.Value -isnot [System.Array]) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_TYPE_INVALID'
                    path = $routePath + '.allowedModes'
                    message = 'Route allowedModes must be an array.'
                })
            } else {
                $allowedModes = @($allowedModesProperty.Value)
                if ($allowedModes.Count -eq 0) {
                    Write-Output ([pscustomobject]@{
                        code = 'FIELD_VALUE_INVALID'
                        path = $routePath + '.allowedModes'
                        message = 'Route allowedModes cannot be empty.'
                    })
                }
                for ($index = 0; $index -lt $allowedModes.Count; $index++) {
                    if ($allowedModes[$index] -isnot [string] -or
                        @('read', 'write') -notcontains [string]$allowedModes[$index]) {
                        Write-Output ([pscustomobject]@{
                            code = 'FIELD_VALUE_INVALID'
                            path = ('{0}.allowedModes[{1}]' -f $routePath, $index)
                            message = 'Route mode is not supported.'
                        })
                    }
                }
            }
        }
    }
}

function Resolve-AiwWorkerExecutablePath {
    param(
        [Parameter(Mandatory)][object]$Worker,
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$ConfigDirectory
    )

    $pathProperty = $Worker.PSObject.Properties['path']
    $configuredPath = if ($null -eq $pathProperty) { $null } else { [string]$pathProperty.Value }
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($configuredPath)
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            $expanded = Join-Path $ConfigDirectory $expanded
        }
        $resolved = [System.IO.Path]::GetFullPath($expanded)
    } else {
        $commandName = switch ($Adapter.id) {
            'claude-code/v1' { 'claude' }
            'antigravity/v1' { 'agy' }
            'minimax-cli/v1' { 'mmx' }
        }
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        $resolved = if ($null -eq $command) { $null } else { [string]$command.Source }
    }
    if ([string]::IsNullOrWhiteSpace($resolved) -or
        -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw 'Configured worker executable was not found.'
    }
    $resolved = (Resolve-Path -LiteralPath $resolved).Path
    $leaf = [System.IO.Path]::GetFileName($resolved).ToLowerInvariant()
    $allowedLeafNames = switch ($Adapter.id) {
        'claude-code/v1' { @('claude.exe', 'claude.ps1') }
        'antigravity/v1' { @('agy.exe', 'agy.ps1') }
        'minimax-cli/v1' { @('mmx.exe', 'mmx.ps1', 'mmx.cmd') }
    }
    if ($allowedLeafNames -notcontains $leaf) {
        throw 'Configured executable filename is not allowed for the adapter.'
    }
    return $resolved
}

function Resolve-AiwConfiguredDirectory {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$ConfigDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $ConfigDirectory $expanded
    }
    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw 'Configured native profile directory does not exist.'
    }
    return (Resolve-Path -LiteralPath $fullPath).Path
}

function New-AiwRunPreflightFailure {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Skipped = @()
    )

    return [pscustomobject]@{
        schemaVersion = 2
        ok = $false
        command = 'run'
        request = [pscustomobject]@{
            worker = $Request.worker
            profile = $Request.profile
            route = $Request.route
            mode = $Request.mode
            requiredCapabilities = @($Request.requiredCapabilities)
        }
        selection = $null
        exitCode = 2
        timedOut = $false
        readTimedOut = $false
        terminationSucceeded = $false
        durationMs = 0
        failureKind = $FailureKind
        skipped = @($Skipped)
        attempts = @()
        output = ''
        error = [pscustomobject]@{
            code = $Code
            phase = 'preflight'
            message = $Message
        }
        errors = @()
        diagnostics = $null
        warnings = @()
    }
}

function New-AiwRunPlan {
    param([Parameter(Mandatory)][object]$Request)

    $validation = New-AiwConfigValidationResult -Path ([string]$Request.configPath)
    if (-not $validation.ok) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $false
            command = 'run'
            request = [pscustomobject]@{
                worker = $Request.worker
                profile = $Request.profile
                route = $Request.route
                mode = $Request.mode
                requiredCapabilities = @($Request.requiredCapabilities)
            }
            selection = $null
            exitCode = 2
            timedOut = $false
            readTimedOut = $false
            terminationSucceeded = $false
            durationMs = 0
            failureKind = 'config_invalid'
            skipped = @()
            attempts = @()
            output = ''
            error = [pscustomobject]@{
                code = 'CONFIG_INVALID'
                phase = 'preflight'
                message = 'Configuration validation failed.'
            }
            errors = @($validation.errors)
            diagnostics = $null
            warnings = @()
        }
    }

    $loaded = Read-AiwConfigDocument -Path ([string]$Request.configPath)
    $selectorValues = @(
        @($Request.worker, $Request.profile, $Request.route) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($selectorValues.Count -gt 1) {
        return New-AiwRunPreflightFailure `
            -Request $Request `
            -Code 'SELECTION_REQUIRED' `
            -FailureKind 'invalid_request' `
            -Message 'Worker, profile, and route selectors are mutually exclusive.'
    }

    $selectedWorkerId = [string]$Request.worker
    $selectedProfileId = [string]$Request.profile
    $selectedRouteId = [string]$Request.route
    if ($selectorValues.Count -eq 0) {
        $defaultRouteProperty = $loaded.document.PSObject.Properties['defaultRoute']
        $defaultProfileProperty = $loaded.document.PSObject.Properties['defaultProfile']
        if ($null -ne $defaultRouteProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$defaultRouteProperty.Value)) {
            $selectedRouteId = [string]$defaultRouteProperty.Value
        } elseif ($null -ne $defaultProfileProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$defaultProfileProperty.Value)) {
            $selectedProfileId = [string]$defaultProfileProperty.Value
        } else {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'SELECTION_REQUIRED' `
                -FailureKind 'selection_required' `
                -Message 'Specify a worker, profile, or route.'
        }
    }

    $routeCapabilities = @()
    if (-not [string]::IsNullOrWhiteSpace($selectedRouteId)) {
        $routeProperty = $loaded.document.routes.PSObject.Properties[$selectedRouteId]
        if ($null -eq $routeProperty) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'ROUTE_NOT_FOUND' `
                -FailureKind 'selection_required' `
                -Message 'Selected route was not found.'
        }
        $routeDefinition = $routeProperty.Value
        $selectedProfileId = [string]$routeDefinition.profile
        $routeCapabilitiesProperty = $routeDefinition.PSObject.Properties['requiredCapabilities']
        if ($null -ne $routeCapabilitiesProperty) {
            $routeCapabilities = @($routeCapabilitiesProperty.Value)
        }
        $allowedModesProperty = $routeDefinition.PSObject.Properties['allowedModes']
        $allowedModes = if ($null -eq $allowedModesProperty) { @('read') } else { @($allowedModesProperty.Value) }
        if ($allowedModes -notcontains [string]$Request.mode) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'POLICY_DENIED' `
                -FailureKind 'policy_denied' `
                -Message 'Selected route does not allow the requested mode.'
        }
    }

    $candidateWorkerIds = @()
    if (-not [string]::IsNullOrWhiteSpace($selectedProfileId)) {
        $profileProperty = $loaded.document.profiles.PSObject.Properties[$selectedProfileId]
        if ($null -eq $profileProperty) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'PROFILE_NOT_FOUND' `
                -FailureKind 'selection_required' `
                -Message 'Selected profile was not found.'
        }
        $candidateWorkerIds = @($profileProperty.Value.workers)
    } elseif (-not [string]::IsNullOrWhiteSpace($selectedWorkerId)) {
        $candidateWorkerIds = @($selectedWorkerId)
    }

    $requiredCapabilities = @('text.reason') + @($Request.requiredCapabilities) + @($routeCapabilities)
    if ([string]$Request.mode -eq 'write') {
        $requiredCapabilities += 'workspace.write'
    }
    $requiredCapabilities = @($requiredCapabilities | Select-Object -Unique)
    $skipped = @()
    $worker = $null
    $adapter = $null
    $filePath = $null
    foreach ($candidateWorkerId in $candidateWorkerIds) {
        $workerProperty = $loaded.document.workers.PSObject.Properties[[string]$candidateWorkerId]
        if ($null -eq $workerProperty) {
            $skipped += [pscustomobject]@{ worker = [string]$candidateWorkerId; reason = 'not_found' }
            continue
        }
        $candidateWorker = $workerProperty.Value
        $enabledProperty = $candidateWorker.PSObject.Properties['enabled']
        if ($null -ne $enabledProperty -and $enabledProperty.Value -eq $false) {
            $skipped += [pscustomobject]@{ worker = [string]$candidateWorkerId; reason = 'disabled' }
            continue
        }
        $candidateAdapter = Get-AiwAdapterDescriptor -Id ([string]$candidateWorker.adapter)
        $configuredCapabilitiesProperty = $candidateWorker.PSObject.Properties['capabilities']
        $effectiveCapabilities = if ($null -eq $configuredCapabilitiesProperty -or
            $null -eq $configuredCapabilitiesProperty.Value) {
            @($candidateAdapter.capabilities)
        } else {
            @($configuredCapabilitiesProperty.Value)
        }
        $missingCapability = $false
        foreach ($capability in $requiredCapabilities) {
            if ($effectiveCapabilities -notcontains $capability) {
                $missingCapability = $true
                break
            }
        }
        if ($missingCapability) {
            if (-not [string]::IsNullOrWhiteSpace($selectedWorkerId)) {
                return New-AiwRunPreflightFailure `
                    -Request $Request `
                    -Code 'CAPABILITY_DENIED' `
                    -FailureKind 'capability_denied' `
                    -Message 'Selected worker does not provide all required capabilities.'
            }
            $skipped += [pscustomobject]@{ worker = [string]$candidateWorkerId; reason = 'capability_denied' }
            continue
        }
        try {
            $candidatePath = Resolve-AiwWorkerExecutablePath `
                -Worker $candidateWorker `
                -Adapter $candidateAdapter `
                -ConfigDirectory (Split-Path -Parent $loaded.path)
        } catch {
            if (-not [string]::IsNullOrWhiteSpace($selectedWorkerId)) {
                return New-AiwRunPreflightFailure `
                    -Request $Request `
                    -Code 'CLI_NOT_FOUND' `
                    -FailureKind 'executable_not_found' `
                    -Message 'Selected worker executable is unavailable.'
            }
            $skipped += [pscustomobject]@{ worker = [string]$candidateWorkerId; reason = 'executable_not_found' }
            continue
        }
        $selectedWorkerId = [string]$candidateWorkerId
        $worker = $candidateWorker
        $adapter = $candidateAdapter
        $filePath = $candidatePath
        break
    }
    if ($null -eq $worker) {
        return New-AiwRunPreflightFailure `
            -Request $Request `
            -Code 'NO_RUNNABLE_WORKER' `
            -FailureKind 'selection_required' `
            -Message 'No configured worker satisfies the request.' `
            -Skipped $skipped
    }

    $modelProperty = $worker.PSObject.Properties['model']
    $model = if ($null -eq $modelProperty) { $null } else { [string]$modelProperty.Value }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw ('{0} workers require a pinned model in explicit v0.3 configuration.' -f $adapter.id)
    }

    $arguments = @()
    $standardInputText = $null
    $environmentOverlay = [pscustomobject]@{}
    $allowBatchWorker = $false
    $temporaryDirectory = $null
    switch ($adapter.id) {
        'claude-code/v1' {
            $permissionMode = if ([string]$Request.mode -eq 'write') { 'acceptEdits' } else { 'plan' }
            $tools = if ([string]$Request.mode -eq 'write') {
                'Read,Glob,Grep,Edit,Write,Bash'
            } else {
                'Read,Glob,Grep'
            }
            $arguments = @(
                '-p', 'Read the complete work order from standard input. Follow it only within the declared tool and permission constraints.',
                '--model', $model,
                '--permission-mode', $permissionMode,
                '--tools', $tools,
                '--no-session-persistence',
                '--output-format', 'json',
                '--max-turns', '20'
            )
            $standardInputText = [string]$Request.promptText
        }
        'antigravity/v1' {
            $artifact = New-AiwAntigravityWorkOrderArtifact -PromptText ([string]$Request.promptText)
            $temporaryDirectory = $artifact.directory
            $arguments = @(
                '--print', ('Read and follow the complete work order in {0}.' -f $artifact.path),
                '--model', $model,
                '--mode', $(if ([string]$Request.mode -eq 'write') { 'accept-edits' } else { 'plan' }),
                '--print-timeout', ('{0}s' -f [string]$Request.timeoutSeconds),
                '--add-dir', [string]$Request.workingDirectory,
                '--add-dir', $artifact.directory,
                '--sandbox',
                '--output-format', 'text'
            )
        }
        'minimax-cli/v1' {
            $settingsProperty = $worker.PSObject.Properties['settings']
            $settings = if ($null -eq $settingsProperty) { $null } else { $settingsProperty.Value }
            $regionProperty = if ($null -eq $settings) { $null } else { $settings.PSObject.Properties['region'] }
            $region = if ($null -eq $regionProperty) { $null } else { [string]$regionProperty.Value }
            $baseUrl = switch ($region) {
                'cn' { 'https://api.minimaxi.com' }
                'global' { 'https://api.minimax.io' }
                default { throw 'MiniMax workers require a reviewed region value.' }
            }
            $artifact = New-AiwMiniMaxMessageArtifact -PromptText ([string]$Request.promptText)
            $temporaryDirectory = $artifact.directory
            $arguments = @(
                '--base-url', $baseUrl,
                '--output', 'json',
                '--non-interactive',
                '--no-color',
                '--timeout', [string]$Request.timeoutSeconds,
                'text', 'chat',
                '--model', $model,
                '--messages-file', $artifact.path,
                '--max-tokens', '4096'
            )
            $environmentValues = [ordered]@{
                MINIMAX_BASE_URL = $baseUrl
            }
            $configDirectoryProperty = if ($null -eq $settings) {
                $null
            } else {
                $settings.PSObject.Properties['configDirectory']
            }
            if ($null -ne $configDirectoryProperty) {
                $environmentValues['MMX_CONFIG_DIR'] = Resolve-AiwConfiguredDirectory `
                    -Value ([string]$configDirectoryProperty.Value) `
                    -ConfigDirectory (Split-Path -Parent $loaded.path)
            }
            $environmentOverlay = [pscustomobject]$environmentValues
            $allowBatchWorker = [System.IO.Path]::GetExtension($filePath).Equals(
                '.cmd',
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
        default {
            throw ('Adapter execution is not implemented: {0}' -f $adapter.id)
        }
    }

    return [pscustomobject]@{
        schemaVersion = 2
        ok = $true
        command = 'run.plan'
        exitCode = 0
        request = [pscustomobject]@{
            worker = [string]$Request.worker
            profile = [string]$Request.profile
            route = [string]$Request.route
            mode = [string]$Request.mode
            requiredCapabilities = @($requiredCapabilities | Select-Object -Unique)
        }
        selection = [pscustomobject]@{
            resolvedProfile = if ([string]::IsNullOrWhiteSpace($selectedProfileId)) { $null } else { $selectedProfileId }
            worker = $selectedWorkerId
            adapter = $adapter.id
            model = $model
        }
        plan = [pscustomobject]@{
            filePath = $filePath
            arguments = $arguments
            workingDirectory = [string]$Request.workingDirectory
            standardInputText = $standardInputText
            environmentOverlay = $environmentOverlay
            allowBatchWorker = $allowBatchWorker
            temporaryDirectory = $temporaryDirectory
        }
        skipped = @($skipped)
        error = $null
        diagnostics = $null
        warnings = @()
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
    $errors = @(Get-AiwUnsafeFieldErrors -Value $loaded.document -Path '$')
    foreach ($property in $loaded.document.PSObject.Properties) {
        if ($allowedTopLevelFields -contains $property.Name) {
            continue
        }
        if (@('command', 'args', 'arguments', 'template', 'script', 'shell', 'hook', 'env') -contains
            $property.Name.ToLowerInvariant()) {
            continue
        }
        $errors += [pscustomobject]@{
            code = 'FIELD_UNKNOWN'
            path = '$.' + $property.Name
            message = 'Configuration field is not supported.'
        }
    }
    $workersProperty = $loaded.document.PSObject.Properties['workers']
    $workersValue = if ($null -eq $workersProperty) { $null } else { $workersProperty.Value }
    $errors += @(Get-AiwWorkerValidationErrors -Workers $workersValue)
    $profilesProperty = $loaded.document.PSObject.Properties['profiles']
    $profilesValue = if ($null -eq $profilesProperty) { $null } else { $profilesProperty.Value }
    $errors += @(Get-AiwProfileValidationErrors -Profiles $profilesValue -Workers $workersValue)
    $routesProperty = $loaded.document.PSObject.Properties['routes']
    $routesValue = if ($null -eq $routesProperty) { $null } else { $routesProperty.Value }
    $errors += @(Get-AiwRouteValidationErrors -Routes $routesValue -Profiles $profilesValue)

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
        'run.plan' {
            return New-AiwRunPlan -Request $Request
        }
        default {
            throw ('Unsupported core command: {0}' -f $commandProperty.Value)
        }
    }
}

Export-ModuleMember -Function Invoke-AiwCore
