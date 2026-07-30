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
        throw 'AIW_CONFIG_NOT_FOUND'
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolvedPath
    if ($item.Length -gt 1048576) {
        throw 'AIW_CONFIG_LIMIT_EXCEEDED'
    }

    $reader = New-Object System.IO.StreamReader(
        $resolvedPath,
        (New-Object System.Text.UTF8Encoding($false, $true)),
        $false
    )
    try {
        try {
            $text = $reader.ReadToEnd()
        } catch {
            throw 'AIW_ENCODING_INVALID'
        }
    } finally {
        $reader.Dispose()
    }
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    $rawValidation = Get-AiwRawJsonValidationResult -Text $text
    if (-not $rawValidation.syntaxOk) {
        throw 'AIW_JSON_INVALID'
    }
    if (@($rawValidation.errors).Count -gt 0) {
        return [pscustomobject]@{
            path = $resolvedPath
            document = $null
            rawErrors = @($rawValidation.errors)
        }
    }
    try {
        $document = $text | ConvertFrom-Json
    } catch {
        throw 'AIW_JSON_INVALID'
    }
    return [pscustomobject]@{
        path = $resolvedPath
        document = $document
        rawErrors = @($rawValidation.errors)
    }
}

function New-AiwConfigValidationFailure {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$ErrorPath,
        [Parameter(Mandatory)][string]$Message
    )

    $displayPath = try {
        [System.IO.Path]::GetFullPath($Path)
    } catch {
        $null
    }
    return [pscustomobject]@{
        schemaVersion = 2
        ok = $false
        command = 'config'
        action = 'validate'
        configSchemaVersion = $null
        configPath = $displayPath
        exitCode = 2
        failureKind = 'config_invalid'
        errors = @(
            [pscustomobject]@{
                code = $Code
                path = $ErrorPath
                message = $Message
            }
        )
        error = [pscustomobject]@{
            code = 'CONFIG_INVALID'
            message = 'Configuration validation failed.'
        }
        diagnostics = $null
        warnings = @()
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

function Add-AiwRawJsonError {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    if ($State.Errors.Count -ge $State.MaxErrors) {
        return
    }
    [void]$State.Errors.Add([pscustomobject]@{
        code = $Code
        path = $Path
        message = $Message
    })
}

function Skip-AiwRawJsonWhitespace {
    param([Parameter(Mandatory)][object]$State)

    while ($State.Index -lt $State.Length) {
        $character = [char]$State.Text[$State.Index]
        if ($character -ne [char]32 -and
            $character -ne [char]9 -and
            $character -ne [char]10 -and
            $character -ne [char]13) {
            break
        }
        $State.Index++
    }
}

function Read-AiwRawJsonStringToken {
    param([Parameter(Mandatory)][object]$State)

    if ($State.Index -ge $State.Length -or
        [char]$State.Text[$State.Index] -ne [char]34) {
        throw 'AIW_JSON_SYNTAX_INVALID'
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    while ($State.Index -lt $State.Length) {
        $character = [char]$State.Text[$State.Index]
        $State.Index++
        if ($character -eq [char]34) {
            return $builder.ToString()
        }
        if ([int]$character -lt 32) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        if ($character -ne [char]92) {
            [void]$builder.Append($character)
            continue
        }
        if ($State.Index -ge $State.Length) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $escape = [char]$State.Text[$State.Index]
        $State.Index++
        switch ($escape) {
            ([char]34) { [void]$builder.Append([char]34); continue }
            ([char]92) { [void]$builder.Append([char]92); continue }
            ([char]47) { [void]$builder.Append([char]47); continue }
            'b' { [void]$builder.Append([char]8); continue }
            'f' { [void]$builder.Append([char]12); continue }
            'n' { [void]$builder.Append([char]10); continue }
            'r' { [void]$builder.Append([char]13); continue }
            't' { [void]$builder.Append([char]9); continue }
            'u' {
                if ($State.Index + 4 -gt $State.Length) {
                    throw 'AIW_JSON_SYNTAX_INVALID'
                }
                $hex = $State.Text.Substring($State.Index, 4)
                if ($hex -notmatch '^[0-9A-Fa-f]{4}$') {
                    throw 'AIW_JSON_SYNTAX_INVALID'
                }
                [void]$builder.Append([char]([Convert]::ToInt32($hex, 16)))
                $State.Index += 4
                continue
            }
            default { throw 'AIW_JSON_SYNTAX_INVALID' }
        }
    }
    throw 'AIW_JSON_SYNTAX_INVALID'
}

function New-AiwRawJsonPropertyPath {
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$Name
    )

    if (Test-AiwSecretConfigFieldName -Name $Name) {
        return $ParentPath + '.<redacted>'
    }
    if ($Name -match '^[A-Za-z_][A-Za-z0-9_-]{0,63}$') {
        return $ParentPath + '.' + $Name
    }
    return $ParentPath + '.<field>'
}

function Read-AiwRawJsonValueToken {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][string]$Path
    )

    Skip-AiwRawJsonWhitespace -State $State
    if ($State.Index -ge $State.Length) {
        throw 'AIW_JSON_SYNTAX_INVALID'
    }
    $character = [char]$State.Text[$State.Index]
    if ($character -eq [char]123) {
        Read-AiwRawJsonObjectToken -State $State -Depth $Depth -Path $Path
        return
    }
    if ($character -eq [char]91) {
        Read-AiwRawJsonArrayToken -State $State -Depth $Depth -Path $Path
        return
    }
    if ($character -eq [char]34) {
        [void](Read-AiwRawJsonStringToken -State $State)
        return
    }

    $start = $State.Index
    while ($State.Index -lt $State.Length) {
        $current = [char]$State.Text[$State.Index]
        if ($current -eq [char]32 -or $current -eq [char]9 -or
            $current -eq [char]10 -or $current -eq [char]13 -or
            $current -eq [char]44 -or $current -eq [char]93 -or
            $current -eq [char]125) {
            break
        }
        $State.Index++
    }
    if ($State.Index -eq $start) {
        throw 'AIW_JSON_SYNTAX_INVALID'
    }
    $literal = $State.Text.Substring($start, $State.Index - $start)
    if ($literal -notmatch '^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$') {
        throw 'AIW_JSON_SYNTAX_INVALID'
    }
}

function Read-AiwRawJsonObjectToken {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][string]$Path
    )

    if ($Depth -gt $State.MaxDepth) {
        Add-AiwRawJsonError `
            -State $State `
            -Code 'CONFIG_LIMIT_EXCEEDED' `
            -Path $Path `
            -Message 'Configuration nesting exceeds the supported limit.'
        throw 'AIW_JSON_DEPTH_LIMIT'
    }
    $State.Index++
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    Skip-AiwRawJsonWhitespace -State $State
    if ($State.Index -lt $State.Length -and [char]$State.Text[$State.Index] -eq [char]125) {
        $State.Index++
        return
    }
    while ($true) {
        Skip-AiwRawJsonWhitespace -State $State
        $name = Read-AiwRawJsonStringToken -State $State
        $propertyPath = New-AiwRawJsonPropertyPath -ParentPath $Path -Name $name
        if ($seen.ContainsKey($name)) {
            Add-AiwRawJsonError `
                -State $State `
                -Code 'FIELD_DUPLICATE' `
                -Path $seen[$name] `
                -Message 'Object property is duplicated case-insensitively.'
        } else {
            $seen.Add($name, $propertyPath)
        }
        Skip-AiwRawJsonWhitespace -State $State
        if ($State.Index -ge $State.Length -or [char]$State.Text[$State.Index] -ne [char]58) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $State.Index++
        Read-AiwRawJsonValueToken -State $State -Depth ($Depth + 1) -Path $propertyPath
        Skip-AiwRawJsonWhitespace -State $State
        if ($State.Index -ge $State.Length) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $delimiter = [char]$State.Text[$State.Index]
        if ($delimiter -eq [char]125) {
            $State.Index++
            return
        }
        if ($delimiter -ne [char]44) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $State.Index++
        Skip-AiwRawJsonWhitespace -State $State
        if ($State.Index -lt $State.Length -and [char]$State.Text[$State.Index] -eq [char]125) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
    }
}

function Read-AiwRawJsonArrayToken {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][string]$Path
    )

    if ($Depth -gt $State.MaxDepth) {
        Add-AiwRawJsonError `
            -State $State `
            -Code 'CONFIG_LIMIT_EXCEEDED' `
            -Path $Path `
            -Message 'Configuration nesting exceeds the supported limit.'
        throw 'AIW_JSON_DEPTH_LIMIT'
    }
    $State.Index++
    Skip-AiwRawJsonWhitespace -State $State
    if ($State.Index -lt $State.Length -and [char]$State.Text[$State.Index] -eq [char]93) {
        $State.Index++
        return
    }
    $index = 0
    while ($true) {
        Read-AiwRawJsonValueToken -State $State -Depth ($Depth + 1) -Path ('{0}[{1}]' -f $Path, $index)
        $index++
        Skip-AiwRawJsonWhitespace -State $State
        if ($State.Index -ge $State.Length) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $delimiter = [char]$State.Text[$State.Index]
        if ($delimiter -eq [char]93) {
            $State.Index++
            return
        }
        if ($delimiter -ne [char]44) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        $State.Index++
        Skip-AiwRawJsonWhitespace -State $State
        if ($State.Index -lt $State.Length -and [char]$State.Text[$State.Index] -eq [char]93) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
    }
}

function Get-AiwRawJsonValidationResult {
    param([AllowEmptyString()][string]$Text)

    $state = [pscustomobject]@{
        Text = $Text
        Index = 0
        Length = $Text.Length
        MaxDepth = 20
        MaxErrors = 64
        Errors = New-Object System.Collections.ArrayList
    }
    try {
        Read-AiwRawJsonValueToken -State $state -Depth 0 -Path '$'
        Skip-AiwRawJsonWhitespace -State $state
        if ($state.Index -ne $state.Length) {
            throw 'AIW_JSON_SYNTAX_INVALID'
        }
        return [pscustomobject]@{
            syntaxOk = $true
            errors = @($state.Errors)
        }
    } catch {
        if ($_.Exception.Message -eq 'AIW_JSON_DEPTH_LIMIT') {
            return [pscustomobject]@{
                syntaxOk = $true
                errors = @($state.Errors)
            }
        }
        return [pscustomobject]@{
            syntaxOk = $false
            errors = @()
        }
    }
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

function Get-AiwExactObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        return $null
    }
    $matches = @(
        $Object.PSObject.Properties |
            Where-Object { $_.Name -ceq $Name } |
            Select-Object -First 1
    )
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-AiwDefaultSelectionValidationErrors {
    param(
        [Parameter(Mandatory)][object]$Document,
        [AllowNull()][object]$Profiles,
        [AllowNull()][object]$Routes
    )

    $resolvedValues = @{}
    foreach ($name in @('defaultRoute', 'defaultProfile')) {
        $property = $Document.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) {
            $resolvedValues[$name] = $null
            continue
        }
        if ($property.Value -isnot [string]) {
            Write-Output ([pscustomobject]@{
                code = 'FIELD_TYPE_INVALID'
                path = '$.' + $name
                message = 'Default selector must be null or a string.'
            })
            $resolvedValues[$name] = $null
            continue
        }
        $value = [string]$property.Value
        if ($value -notmatch '^[a-z][a-z0-9._-]{0,63}$') {
            Write-Output ([pscustomobject]@{
                code = 'ID_INVALID'
                path = '$.' + $name
                message = 'Default selector ID is invalid.'
            })
            $resolvedValues[$name] = $null
            continue
        }
        $resolvedValues[$name] = $value
    }

    if ($null -ne $resolvedValues['defaultRoute'] -and
        $null -ne $resolvedValues['defaultProfile']) {
        Write-Output ([pscustomobject]@{
            code = 'DEFAULT_SELECTION_CONFLICT'
            path = '$'
            message = 'Only one default selector may be configured.'
        })
    }
    if ($null -ne $resolvedValues['defaultRoute'] -and
        $null -eq (Get-AiwExactObjectProperty -Object $Routes -Name $resolvedValues['defaultRoute'])) {
        Write-Output ([pscustomobject]@{
            code = 'ROUTE_NOT_FOUND'
            path = '$.defaultRoute'
            message = 'Default route does not exist.'
        })
    }
    if ($null -ne $resolvedValues['defaultProfile'] -and
        $null -eq (Get-AiwExactObjectProperty -Object $Profiles -Name $resolvedValues['defaultProfile'])) {
        Write-Output ([pscustomobject]@{
            code = 'PROFILE_NOT_FOUND'
            path = '$.defaultProfile'
            message = 'Default profile does not exist.'
        })
    }
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

        if ($null -ne $pathProperty -and $pathProperty.Value -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            $configuredLeaf = [System.IO.Path]::GetFileName(
                [Environment]::ExpandEnvironmentVariables([string]$pathProperty.Value)
            ).ToLowerInvariant()
            $allowedLeafNames = switch ($adapter.id) {
                'claude-code/v1' { @('claude.exe', 'claude.ps1') }
                'antigravity/v1' { @('agy.exe', 'agy.ps1') }
                'minimax-cli/v1' { @('mmx.exe', 'mmx.ps1', 'mmx.cmd') }
            }
            if ($allowedLeafNames -notcontains $configuredLeaf) {
                Write-Output ([pscustomobject]@{
                    code = 'LAUNCHER_UNSAFE'
                    path = $workerPath + '.path'
                    message = 'Worker path must use the reviewed executable filename for its adapter.'
                })
            }
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
        if ($null -ne $fallbackProperty -and $null -ne $fallbackProperty.Value) {
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
        $seenWorkerIds = @{}
        for ($index = 0; $index -lt $workerList.Count; $index++) {
            $workerId = [string]$workerList[$index]
            if ($seenWorkerIds.ContainsKey($workerId)) {
                Write-Output ([pscustomobject]@{
                    code = 'FIELD_VALUE_INVALID'
                    path = ('{0}.workers[{1}]' -f $profilePath, $index)
                    message = 'Profile worker references must be unique.'
                })
                continue
            }
            $seenWorkerIds[$workerId] = $true
            if ($null -eq (Get-AiwExactObjectProperty -Object $Workers -Name $workerId)) {
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
            $null -eq (Get-AiwExactObjectProperty -Object $Profiles -Name $profileId)) {
            Write-Output ([pscustomobject]@{
                code = 'PROFILE_NOT_FOUND'
                path = $routePath + '.profile'
                message = 'Route references an unknown profile.'
            })
        }
        $defaultModeProperty = $route.PSObject.Properties['defaultMode']
        if ($null -ne $defaultModeProperty -and
            $null -ne $defaultModeProperty.Value -and
            [string]$defaultModeProperty.Value -ne 'read') {
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

function Find-AiwDiscoveredExecutablePath {
    param([Parameter(Mandatory)][object]$Adapter)

    $commandName = switch ($Adapter.id) {
        'claude-code/v1' { 'claude' }
        'antigravity/v1' { 'agy' }
        'minimax-cli/v1' { 'mmx' }
        default { return $null }
    }
    $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source) -or
        -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return $null
    }
    $resolved = (Resolve-Path -LiteralPath $command.Source).Path
    $leaf = [System.IO.Path]::GetFileName($resolved).ToLowerInvariant()
    $allowedLeafNames = switch ($Adapter.id) {
        'claude-code/v1' { @('claude.exe', 'claude.ps1') }
        'antigravity/v1' { @('agy.exe', 'agy.ps1') }
        'minimax-cli/v1' { @('mmx.exe', 'mmx.ps1', 'mmx.cmd') }
    }
    if ($allowedLeafNames -notcontains $leaf) {
        return $null
    }
    return $resolved
}

function New-AiwDiscoveredConfigDocument {
    $workers = [ordered]@{}
    $inventory = @()
    foreach ($adapter in @(Get-AiwAdapterCatalog)) {
        $path = Find-AiwDiscoveredExecutablePath -Adapter $adapter
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $workerId = switch ($adapter.id) {
            'claude-code/v1' { 'discovered-claude-code' }
            'antigravity/v1' { 'discovered-antigravity' }
            'minimax-cli/v1' { 'discovered-minimax-cli' }
        }
        $settings = [ordered]@{}
        $runnable = $true
        $warning = $null
        if ($adapter.id -eq 'minimax-cli/v1') {
            # Region determines a reviewed endpoint and cannot be guessed from PATH.
            $runnable = $false
            $warning = 'MiniMax discovery requires an explicit configured region before execution.'
        }
        $inventory += [pscustomobject]@{
            worker = $workerId
            adapter = $adapter.id
            path = $path
            available = $true
            runnable = $runnable
            model = $null
            modelPinned = $false
            capabilities = @($adapter.capabilities)
            provenance = 'discovered'
            warning = $warning
        }
        if ($runnable) {
            $workers[$workerId] = [ordered]@{
                adapter = $adapter.id
                enabled = $true
                path = $path
                model = $null
                capabilities = @($adapter.capabilities)
                settings = $settings
            }
        }
    }
    $document = [ordered]@{
        schemaVersion = 2
        defaultRoute = $null
        defaultProfile = $null
        workers = $workers
        profiles = [ordered]@{}
        routes = [ordered]@{}
    }
    return [pscustomobject]@{
        path = $null
        configDirectory = [Environment]::CurrentDirectory
        document = ((ConvertTo-Json -InputObject $document -Depth 20) | ConvertFrom-Json)
        rawErrors = @()
        inventory = @($inventory)
        provenance = 'discovered'
    }
}

function New-AiwInventoryResult {
    param(
        [AllowNull()][string]$ConfigPath,
        [ValidateSet('status', 'doctor')][string]$OutputCommand = 'status'
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $discovered = New-AiwDiscoveredConfigDocument
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $true
            command = $OutputCommand
            exitCode = 0
            configLoaded = $false
            configPath = $null
            provenance = 'discovered'
            workers = @($discovered.inventory)
            profiles = @()
            routes = @()
            adapters = @(Get-AiwAdapterCatalog)
            error = $null
            diagnostics = $null
            warnings = @('No explicit v2 configuration was found; discovery did not create a configuration or choose a default worker.')
        }
    }

    $validation = New-AiwConfigValidationResult -Path $ConfigPath
    if (-not $validation.ok) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $false
            command = $OutputCommand
            exitCode = 2
            configLoaded = $true
            configPath = $validation.configPath
            provenance = 'configured'
            workers = @()
            profiles = @()
            routes = @()
            adapters = @(Get-AiwAdapterCatalog)
            error = $validation.error
            errors = @($validation.errors)
            diagnostics = $null
            warnings = @()
        }
    }
    if ($validation.configSchemaVersion -eq 1) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $true
            command = $OutputCommand
            exitCode = 0
            configLoaded = $true
            configPath = $validation.configPath
            provenance = 'legacy-v1'
            workers = @()
            profiles = @()
            routes = @()
            adapters = @(Get-AiwAdapterCatalog)
            error = $null
            diagnostics = $null
            warnings = @('Schema v1 inventory remains available through the compatibility facade; use config migrate for v2 worker inventory.')
        }
    }

    $loaded = Read-AiwConfigDocument -Path $ConfigPath
    $configDirectory = Split-Path -Parent $loaded.path
    $workers = @()
    foreach ($property in $loaded.document.workers.PSObject.Properties) {
        $worker = $property.Value
        $adapter = Get-AiwAdapterDescriptor -Id ([string]$worker.adapter)
        $resolvedPath = $null
        $availability = 'unavailable'
        try {
            $resolvedPath = Resolve-AiwWorkerExecutablePath `
                -Worker $worker `
                -Adapter $adapter `
                -ConfigDirectory $configDirectory
            $availability = 'available'
        } catch {
            $availability = 'unavailable'
        }
        $profileDirectory = $null
        $profileDirectoryExists = $null
        $settings = Get-AiwMigrationPropertyValue -Object $worker -Name 'settings'
        if ($adapter.id -in @('claude-code/v1', 'minimax-cli/v1') -and $settings -is [pscustomobject]) {
            $configDirectoryProperty = $settings.PSObject.Properties['configDirectory']
            if ($null -ne $configDirectoryProperty -and
                $null -ne $configDirectoryProperty.Value) {
                $profileProbe = Get-AiwConfiguredDirectoryProbe `
                    -Value ([string]$configDirectoryProperty.Value) `
                    -ConfigDirectory $configDirectory
                $profileDirectory = $profileProbe.path
                $profileDirectoryExists = $profileProbe.exists
                if ($availability -eq 'available' -and -not $profileDirectoryExists) {
                    $availability = 'profile_unavailable'
                }
            }
        }
        $model = Get-AiwMigrationPropertyValue -Object $worker -Name 'model'
        $workers += [pscustomobject]@{
            worker = $property.Name
            adapter = $adapter.id
            path = $resolvedPath
            available = ($availability -eq 'available')
            availability = $availability
            executableAvailable = -not [string]::IsNullOrWhiteSpace($resolvedPath)
            profileDirectory = $profileDirectory
            profileDirectoryExists = $profileDirectoryExists
            enabled = [bool](Get-AiwMigrationPropertyValue -Object $worker -Name 'enabled' -DefaultValue $true)
            model = $model
            modelPinned = -not [string]::IsNullOrWhiteSpace([string]$model)
            capabilities = @(
                Get-AiwMigrationPropertyValue -Object $worker -Name 'capabilities' -DefaultValue @($adapter.capabilities)
            )
            provenance = 'configured'
        }
    }
    $profiles = @()
    foreach ($property in $loaded.document.profiles.PSObject.Properties) {
        $profile = $property.Value
        $fallbackDefinition = Get-AiwMigrationPropertyValue -Object $profile -Name 'fallback'
        $fallbackMaxAttempts = 1
        $fallbackFailureKinds = @()
        if ($fallbackDefinition -is [pscustomobject]) {
            $fallbackMaxAttempts = [int](
                Get-AiwMigrationPropertyValue `
                    -Object $fallbackDefinition `
                    -Name 'maxAttempts' `
                    -DefaultValue 1
            )
            $fallbackFailureKinds = @(
                Get-AiwMigrationPropertyValue `
                    -Object $fallbackDefinition `
                    -Name 'on' `
                    -DefaultValue @()
            )
        }
        $profiles += [pscustomobject]@{
            profile = $property.Name
            workers = @(
                Get-AiwMigrationPropertyValue -Object $profile -Name 'workers' -DefaultValue @()
            )
            fallback = [pscustomobject]@{
                maxAttempts = $fallbackMaxAttempts
                on = @($fallbackFailureKinds)
            }
        }
    }
    $routes = @()
    foreach ($property in $loaded.document.routes.PSObject.Properties) {
        $route = $property.Value
        $routes += [pscustomobject]@{
            route = $property.Name
            profile = [string](
                Get-AiwMigrationPropertyValue -Object $route -Name 'profile' -DefaultValue ''
            )
            requiredCapabilities = @(
                Get-AiwMigrationPropertyValue `
                    -Object $route `
                    -Name 'requiredCapabilities' `
                    -DefaultValue @()
            )
            defaultMode = [string](
                Get-AiwMigrationPropertyValue -Object $route -Name 'defaultMode' -DefaultValue 'read'
            )
            allowedModes = @(
                Get-AiwMigrationPropertyValue `
                    -Object $route `
                    -Name 'allowedModes' `
                    -DefaultValue @('read')
            )
        }
    }
    $enabledWorkers = @($workers | Where-Object { $_.enabled })
    $runnableWorkers = @($enabledWorkers | Where-Object { $_.available })
    $doctorUnusable = $OutputCommand -eq 'doctor' -and
        $enabledWorkers.Count -gt 0 -and
        $runnableWorkers.Count -eq 0
    $doctorError = if ($doctorUnusable) {
        [pscustomobject]@{
            code = 'CONFIGURED_WORKERS_UNAVAILABLE'
            phase = 'discovery'
            message = 'No enabled configured worker executable is available.'
        }
    } else {
        $null
    }
    $warnings = @()
    if ($doctorUnusable) {
        $warnings += 'All enabled configured workers are unavailable. Correct the worker paths or disable unavailable workers.'
    }
    return [pscustomobject]@{
        schemaVersion = 2
        ok = (-not $doctorUnusable)
        command = $OutputCommand
        exitCode = if ($doctorUnusable) { 1 } else { 0 }
        configLoaded = $true
        configPath = $loaded.path
        provenance = 'configured'
        workers = @($workers)
        profiles = @($profiles)
        routes = @($routes)
        adapters = @(Get-AiwAdapterCatalog)
        error = $doctorError
        diagnostics = $null
        warnings = @($warnings)
    }
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

function Get-AiwConfiguredDirectoryProbe {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$ConfigDirectory
    )

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Value)
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            $expanded = Join-Path $ConfigDirectory $expanded
        }
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    } catch {
        return [pscustomobject]@{ path = $null; exists = $false }
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        return [pscustomobject]@{ path = $fullPath; exists = $false }
    }
    return [pscustomobject]@{
        path = (Resolve-Path -LiteralPath $fullPath).Path
        exists = $true
    }
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
        outputLimitExceeded = $false
        cleanupFailed = $false
        terminationSucceeded = $false
        containmentApplied = $false
        treeTerminationConfirmed = $false
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

    $configuredPath = [string]$Request.configPath
    $usingDiscovery = [string]::IsNullOrWhiteSpace($configuredPath)
    if ($usingDiscovery) {
        $loaded = New-AiwDiscoveredConfigDocument
    } else {
        $validation = New-AiwConfigValidationResult -Path $configuredPath
        if (-not $validation.ok) {
            $failure = New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'CONFIG_INVALID' `
                -FailureKind 'config_invalid' `
                -Message 'Configuration validation failed.'
            $failure.errors = @($validation.errors)
            return $failure
        }
        if ($validation.configSchemaVersion -eq 1) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'CONFIG_MIGRATION_REQUIRED' `
                -FailureKind 'config_invalid' `
                -Message 'Schema v1 requires an explicit v2 migration before the generic run command can use it.'
        }
        $loaded = Read-AiwConfigDocument -Path $configuredPath
    }
    $loadedConfigDirectory = if ([string]::IsNullOrWhiteSpace([string]$loaded.path)) {
        [string]$loaded.configDirectory
    } else {
        Split-Path -Parent $loaded.path
    }
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
        if ($null -ne $routeCapabilitiesProperty -and
            $null -ne $routeCapabilitiesProperty.Value) {
            $routeCapabilities = @($routeCapabilitiesProperty.Value)
        }
        $allowedModesProperty = $routeDefinition.PSObject.Properties['allowedModes']
        $allowedModes = if ($null -eq $allowedModesProperty -or
            $null -eq $allowedModesProperty.Value) { @('read') } else { @($allowedModesProperty.Value) }
        if ($allowedModes -notcontains [string]$Request.mode) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'POLICY_DENIED' `
                -FailureKind 'policy_denied' `
                -Message 'Selected route does not allow the requested mode.'
        }
    }

    $candidateWorkerIds = @()
    $profileDefinition = $null
    if (-not [string]::IsNullOrWhiteSpace($selectedProfileId)) {
        $profileProperty = $loaded.document.profiles.PSObject.Properties[$selectedProfileId]
        if ($null -eq $profileProperty) {
            return New-AiwRunPreflightFailure `
                -Request $Request `
                -Code 'PROFILE_NOT_FOUND' `
                -FailureKind 'selection_required' `
                -Message 'Selected profile was not found.'
        }
        $profileDefinition = $profileProperty.Value
        $candidateWorkerIds = @($profileDefinition.workers)
    } elseif (-not [string]::IsNullOrWhiteSpace($selectedWorkerId)) {
        $candidateWorkerIds = @($selectedWorkerId)
    }

    $selectorKind = if (-not [string]::IsNullOrWhiteSpace($selectedRouteId)) {
        'route'
    } elseif (-not [string]::IsNullOrWhiteSpace($selectedProfileId)) {
        'profile'
    } else {
        'worker'
    }
    $fallbackMaxAttempts = 1
    $fallbackFailureKinds = @()
    if ($null -ne $profileDefinition) {
        $fallbackProperty = $profileDefinition.PSObject.Properties['fallback']
        if ($null -ne $fallbackProperty -and $null -ne $fallbackProperty.Value) {
            $maxAttemptsProperty = $fallbackProperty.Value.PSObject.Properties['maxAttempts']
            if ($null -ne $maxAttemptsProperty -and $null -ne $maxAttemptsProperty.Value) {
                $fallbackMaxAttempts = [int]$maxAttemptsProperty.Value
            }
            $onProperty = $fallbackProperty.Value.PSObject.Properties['on']
            if ($null -ne $onProperty -and $null -ne $onProperty.Value) {
                $fallbackFailureKinds = @($onProperty.Value)
            }
        }
    }
    $excludedWorkersProperty = $Request.PSObject.Properties['excludedWorkers']
    $excludedWorkers = if ($null -eq $excludedWorkersProperty -or
        $null -eq $excludedWorkersProperty.Value) {
        @()
    } else {
        @($excludedWorkersProperty.Value)
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
        if ($excludedWorkers -contains [string]$candidateWorkerId) {
            continue
        }
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
                -ConfigDirectory $loadedConfigDirectory
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
    $model = if ($null -eq $modelProperty -or $null -eq $modelProperty.Value) {
        $null
    } else {
        [string]$modelProperty.Value
    }
    if ($adapter.id -eq 'minimax-cli/v1' -and [string]::IsNullOrWhiteSpace($model)) {
        throw 'MiniMax workers require a pinned model in explicit v0.3 configuration.'
    }

    $arguments = @()
    $standardInputText = $null
    $environmentOverlay = [pscustomobject]@{}
    $allowBatchWorker = $false
    $artifactPlan = $null
    switch ($adapter.id) {
        'claude-code/v1' {
            $permissionMode = if ([string]$Request.mode -eq 'write') { 'acceptEdits' } else { 'plan' }
            $tools = if ([string]$Request.mode -eq 'write') {
                'Read,Glob,Grep,Edit,Write,Bash'
            } else {
                'Read,Glob,Grep'
            }
            $settingsProperty = $worker.PSObject.Properties['settings']
            $settings = if ($null -eq $settingsProperty) { $null } else { $settingsProperty.Value }
            $configDirectoryProperty = if ($null -eq $settings) {
                $null
            } else {
                $settings.PSObject.Properties['configDirectory']
            }
            if ($null -ne $configDirectoryProperty) {
                try {
                    $resolvedProfileDirectory = Resolve-AiwConfiguredDirectory `
                        -Value ([string]$configDirectoryProperty.Value) `
                        -ConfigDirectory $loadedConfigDirectory
                } catch {
                    return New-AiwRunPreflightFailure `
                        -Request $Request `
                        -Code 'PROFILE_DIRECTORY_INVALID' `
                        -FailureKind 'profile_directory_invalid' `
                        -Message 'Selected worker profile directory is unavailable.' `
                        -Skipped $skipped
                }
                $environmentOverlay = [pscustomobject]@{
                    CLAUDE_CONFIG_DIR = $resolvedProfileDirectory
                }
            }
            $arguments = @(
                '-p', 'Read the complete work order from standard input. Follow it only within the declared tool and permission constraints.'
            )
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                $arguments += @('--model', $model)
            }
            $arguments += @(
                '--permission-mode', $permissionMode,
                '--tools', $tools,
                '--no-session-persistence',
                '--output-format', 'json',
                '--max-turns', '20'
            )
            $standardInputText = [string]$Request.promptText
        }
        'antigravity/v1' {
            $arguments = @(
                '--print', $null
            )
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                $arguments += @('--model', $model)
            }
            $arguments += @(
                '--mode', $(if ([string]$Request.mode -eq 'write') { 'accept-edits' } else { 'plan' }),
                '--print-timeout', ('{0}s' -f [string]$Request.timeoutSeconds),
                '--add-dir', [string]$Request.workingDirectory
            )
            $artifactDirectoryArgumentIndex = $arguments.Count + 1
            $arguments += @(
                '--add-dir', $null,
                '--sandbox',
                '--output-format', 'text'
            )
            $artifactPlan = [pscustomobject]@{
                kind = 'antigravity-work-order'
                promptText = [string]$Request.promptText
                fileArgumentIndex = 1
                fileArgumentFormat = 'Read and follow the complete work order in {0}.'
                directoryArgumentIndex = $artifactDirectoryArgumentIndex
            }
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
            $configDirectoryProperty = if ($null -eq $settings) {
                $null
            } else {
                $settings.PSObject.Properties['configDirectory']
            }
            $resolvedProfileDirectory = $null
            if ($null -ne $configDirectoryProperty) {
                try {
                    $resolvedProfileDirectory = Resolve-AiwConfiguredDirectory `
                        -Value ([string]$configDirectoryProperty.Value) `
                        -ConfigDirectory $loadedConfigDirectory
                } catch {
                    return New-AiwRunPreflightFailure `
                        -Request $Request `
                        -Code 'PROFILE_DIRECTORY_INVALID' `
                        -FailureKind 'profile_directory_invalid' `
                        -Message 'Selected worker profile directory is unavailable.' `
                        -Skipped $skipped
                }
            }
            $arguments = @(
                '--base-url', $baseUrl,
                '--output', 'json',
                '--non-interactive',
                '--no-color',
                '--timeout', [string]$Request.timeoutSeconds,
                'text', 'chat',
                '--model', $model,
                '--messages-file'
            )
            $artifactFileArgumentIndex = $arguments.Count
            $arguments += @(
                $null,
                '--max-tokens', '4096'
            )
            $artifactPlan = [pscustomobject]@{
                kind = 'minimax-messages'
                promptText = [string]$Request.promptText
                fileArgumentIndex = $artifactFileArgumentIndex
                fileArgumentFormat = '{0}'
                directoryArgumentIndex = $null
            }
            $environmentValues = [ordered]@{
                MINIMAX_BASE_URL = $baseUrl
            }
            if ($null -ne $configDirectoryProperty) {
                $environmentValues['MMX_CONFIG_DIR'] = $resolvedProfileDirectory
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
        fallbackPolicy = [pscustomobject]@{
            selectorKind = $selectorKind
            maxAttempts = $fallbackMaxAttempts
            on = @($fallbackFailureKinds)
        }
        plan = [pscustomobject]@{
            filePath = $filePath
            arguments = $arguments
            workingDirectory = [string]$Request.workingDirectory
            standardInputText = $standardInputText
            environmentOverlay = $environmentOverlay
            allowBatchWorker = $allowBatchWorker
            artifact = $artifactPlan
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

    try {
        $loaded = Read-AiwConfigDocument -Path $Path
    } catch {
        $detailCode = switch ($_.Exception.Message) {
            'AIW_CONFIG_NOT_FOUND' { 'CONFIG_NOT_FOUND' }
            'AIW_CONFIG_LIMIT_EXCEEDED' { 'CONFIG_LIMIT_EXCEEDED' }
            'AIW_ENCODING_INVALID' { 'ENCODING_INVALID' }
            'AIW_JSON_INVALID' { 'JSON_INVALID' }
            default { 'JSON_INVALID' }
        }
        return New-AiwConfigValidationFailure `
            -Path $Path `
            -Code $detailCode `
            -ErrorPath '$' `
            -Message 'Configuration could not be parsed safely.'
    }
    if (@($loaded.rawErrors).Count -gt 0) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $false
            command = 'config'
            action = 'validate'
            configSchemaVersion = $null
            configPath = $loaded.path
            exitCode = 2
            failureKind = 'config_invalid'
            errors = @($loaded.rawErrors)
            error = [pscustomobject]@{
                code = 'CONFIG_INVALID'
                message = 'Configuration validation failed.'
            }
            diagnostics = $null
            warnings = @()
        }
    }
    if ($null -eq $loaded.document -or $loaded.document -isnot [pscustomobject]) {
        return New-AiwConfigValidationFailure `
            -Path $loaded.path `
            -Code 'FIELD_TYPE_INVALID' `
            -ErrorPath '$' `
            -Message 'Configuration root must be a JSON object.'
    }
    $schemaProperty = $loaded.document.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or
        -not (Test-AiwIntegerValue -Value $schemaProperty.Value) -or
        @([int64]1, [int64]2) -notcontains [int64]$schemaProperty.Value) {
        return New-AiwConfigValidationFailure `
            -Path $loaded.path `
            -Code 'SCHEMA_VERSION_UNSUPPORTED' `
            -ErrorPath '$.schemaVersion' `
            -Message 'Configuration schemaVersion must be the integer 1 or 2.'
    }
    if ([int64]$schemaProperty.Value -eq 1) {
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $true
            command = 'config'
            action = 'validate'
            configSchemaVersion = 1
            configPath = $loaded.path
            exitCode = 0
            failureKind = $null
            errors = @()
            error = $null
            diagnostics = $null
            warnings = @('Schema v1 remains supported through the frozen compatibility facade; migrate to schema v2 for generic routing.')
        }
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
    $errors += @(
        Get-AiwDefaultSelectionValidationErrors `
            -Document $loaded.document `
            -Profiles $profilesValue `
            -Routes $routesValue
    )

    if ($errors.Count -gt 0) {
        $sortedErrors = @($errors | Sort-Object path, code)
        $maximumReportedErrors = 64
        $errorsTruncated = $sortedErrors.Count -gt $maximumReportedErrors
        $reportedErrors = @($sortedErrors | Select-Object -First $maximumReportedErrors)
        $warnings = @()
        if ($errorsTruncated) {
            $warnings += 'Configuration validation errors were truncated to the first 64 stable entries.'
        }
        return [pscustomobject]@{
            schemaVersion = 2
            ok = $false
            command = 'config'
            action = 'validate'
            configSchemaVersion = 2
            configPath = $loaded.path
            exitCode = 2
            failureKind = 'config_invalid'
            errors = @($reportedErrors)
            errorCount = [int]$sortedErrors.Count
            errorsTruncated = $errorsTruncated
            error = [pscustomobject]@{
                code = 'CONFIG_INVALID'
                message = 'Configuration validation failed.'
            }
            diagnostics = $null
            warnings = @($warnings)
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

function New-AiwConfigMigrationFailure {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowNull()][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    return [pscustomobject]@{
        schemaVersion = 2
        ok = $false
        command = 'config'
        action = 'migrate'
        sourcePath = $SourcePath
        destinationPath = $DestinationPath
        exitCode = 2
        failureKind = 'config_invalid'
        errors = @([pscustomobject]@{
            code = $Code
            path = '$'
            message = $Message
        })
        error = [pscustomobject]@{
            code = 'CONFIG_MIGRATION_FAILED'
            message = 'Configuration migration was not applied.'
        }
        diagnostics = $null
        warnings = @()
    }
}

function Get-AiwMigrationPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    $property = Get-AiwExactObjectProperty -Object $Object -Name $Name
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-AiwMigrationSafeString {
    param(
        [AllowNull()][object]$Value,
        [AllowNull()][object]$DefaultValue = $null,
        [int]$MaximumLength = 256
    )

    if ($Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Value) -and
        ([string]$Value).Length -le $MaximumLength -and
        [string]$Value -notmatch '[\x00-\x1F\x7F]') {
        return [string]$Value
    }
    return $DefaultValue
}

function Get-AiwMigrationSafeModel {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$DefaultValue
    )

    if ($Value -is [string] -and [string]$Value -match '^[A-Za-z0-9._-]{1,128}$') {
        return [string]$Value
    }
    return $DefaultValue
}

function Get-AiwMigrationConfigDirectory {
    param([AllowNull()][object]$LegacyValue)

    $safeValue = Get-AiwMigrationSafeString -Value $LegacyValue -MaximumLength 1024
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return $null
    }
    $parent = Split-Path -Parent $safeValue
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return $null
    }
    return $parent
}

function New-AiwMigratedWorker {
    param(
        [Parameter(Mandatory)][object]$LegacyWorkers,
        [Parameter(Mandatory)][string]$LegacyId,
        [Parameter(Mandatory)][string]$Adapter,
        [Parameter(Mandatory)][string]$DefaultModel,
        [Parameter(Mandatory)][string[]]$Capabilities,
        [ValidateSet('none', 'configDirectory', 'configPathDirectory')][string]$SettingsMode = 'none'
    )

    $legacyWorker = Get-AiwMigrationPropertyValue -Object $LegacyWorkers -Name $LegacyId
    $model = Get-AiwMigrationSafeModel `
        -Value (Get-AiwMigrationPropertyValue -Object $legacyWorker -Name 'model') `
        -DefaultValue $DefaultModel
    $path = Get-AiwMigrationSafeString `
        -Value (Get-AiwMigrationPropertyValue -Object $legacyWorker -Name 'path') `
        -MaximumLength 1024
    $settings = [ordered]@{}
    if ($SettingsMode -eq 'configDirectory') {
        $directory = Get-AiwMigrationSafeString `
            -Value (Get-AiwMigrationPropertyValue -Object $legacyWorker -Name 'configDirectory') `
            -MaximumLength 1024
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $settings['configDirectory'] = $directory
        }
    } elseif ($SettingsMode -eq 'configPathDirectory') {
        $directory = Get-AiwMigrationConfigDirectory `
            -LegacyValue (Get-AiwMigrationPropertyValue -Object $legacyWorker -Name 'configPath')
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $settings['configDirectory'] = $directory
        }
    }

    return [ordered]@{
        adapter = $Adapter
        enabled = $true
        path = $path
        model = $model
        capabilities = @($Capabilities)
        settings = $settings
    }
}

function Invoke-AiwConfigMigration {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowNull()][string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $SourcePath `
            -DestinationPath $DestinationPath `
            -Code 'DESTINATION_REQUIRED' `
            -Message 'Migration requires a new destination path.'
    }

    try {
        $source = Read-AiwConfigDocument -Path $SourcePath
    } catch {
        $code = switch ($_.Exception.Message) {
            'AIW_CONFIG_NOT_FOUND' { 'CONFIG_NOT_FOUND' }
            'AIW_CONFIG_LIMIT_EXCEEDED' { 'CONFIG_LIMIT_EXCEEDED' }
            'AIW_ENCODING_INVALID' { 'ENCODING_INVALID' }
            default { 'JSON_INVALID' }
        }
        return New-AiwConfigMigrationFailure `
            -SourcePath $SourcePath `
            -DestinationPath $DestinationPath `
            -Code $code `
            -Message 'Migration source could not be parsed safely.'
    }
    if (@($source.rawErrors).Count -gt 0) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $DestinationPath `
            -Code 'CONFIG_INVALID' `
            -Message 'Migration source contains unsafe duplicate properties.'
    }
    if ($null -eq $source.document -or $source.document -isnot [pscustomobject]) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $DestinationPath `
            -Code 'MIGRATION_SOURCE_INVALID' `
            -Message 'Migration source must be a JSON object.'
    }
    $schemaProperty = Get-AiwExactObjectProperty -Object $source.document -Name 'schemaVersion'
    if ($null -eq $schemaProperty -or
        -not (Test-AiwIntegerValue -Value $schemaProperty.Value) -or
        [int64]$schemaProperty.Value -ne 1) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $DestinationPath `
            -Code 'MIGRATION_SOURCE_SCHEMA_UNSUPPORTED' `
            -Message 'Only schema v1 configuration can be migrated.'
    }

    try {
        $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)
    } catch {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $DestinationPath `
            -Code 'DESTINATION_INVALID' `
            -Message 'Migration destination path is invalid.'
    }
    if ($destinationFull.Equals($source.path, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $destinationFull `
            -Code 'DESTINATION_SOURCE_CONFLICT' `
            -Message 'Migration destination must differ from the source.'
    }
    if (Test-Path -LiteralPath $destinationFull) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $destinationFull `
            -Code 'DESTINATION_EXISTS' `
            -Message 'Migration destination already exists.'
    }
    $destinationDirectory = Split-Path -Parent $destinationFull
    if ([string]::IsNullOrWhiteSpace($destinationDirectory) -or
        -not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $destinationFull `
            -Code 'DESTINATION_DIRECTORY_NOT_FOUND' `
            -Message 'Migration destination directory must already exist.'
    }

    $legacyWorkers = Get-AiwMigrationPropertyValue -Object $source.document -Name 'workers'
    if ($legacyWorkers -isnot [pscustomobject]) {
        $legacyWorkers = [pscustomobject]@{}
    }
    $miniMaxLegacy = Get-AiwMigrationPropertyValue -Object $legacyWorkers -Name 'minimax'
    $legacyBaseUrl = Get-AiwMigrationSafeString `
        -Value (Get-AiwMigrationPropertyValue -Object $miniMaxLegacy -Name 'baseUrl') `
        -MaximumLength 256
    $miniMaxRegion = if ($legacyBaseUrl -eq 'https://api.minimax.io') { 'global' } else { 'cn' }

    $migratedWorkers = [ordered]@{}
    $migratedWorkers['legacy-ark'] = New-AiwMigratedWorker `
        -LegacyWorkers $legacyWorkers `
        -LegacyId 'ark' `
        -Adapter 'claude-code/v1' `
        -DefaultModel 'glm-5.2' `
        -Capabilities @('text.reason', 'workspace.read', 'workspace.write') `
        -SettingsMode 'configPathDirectory'
    $migratedAgent = New-AiwMigratedWorker `
        -LegacyWorkers $legacyWorkers `
        -LegacyId 'agent' `
        -Adapter 'claude-code/v1' `
        -DefaultModel 'ark-code-latest' `
        -Capabilities @('text.reason', 'workspace.read', 'workspace.write') `
        -SettingsMode 'configDirectory'
    if (-not $migratedAgent.settings.Contains('configDirectory')) {
        # Schema v1 used this isolated Agent Plan profile when the field was absent.
        $migratedAgent.settings['configDirectory'] = '%USERPROFILE%\.claude-agent-plan'
    }
    $migratedWorkers['legacy-agent'] = $migratedAgent
    $migratedWorkers['legacy-google'] = New-AiwMigratedWorker `
        -LegacyWorkers $legacyWorkers `
        -LegacyId 'google' `
        -Adapter 'antigravity/v1' `
        -DefaultModel 'gemini-3.6-flash-high' `
        -Capabilities @('text.reason', 'context.long', 'workspace.read', 'workspace.write')
    $migratedMiniMax = New-AiwMigratedWorker `
        -LegacyWorkers $legacyWorkers `
        -LegacyId 'minimax' `
        -Adapter 'minimax-cli/v1' `
        -DefaultModel 'MiniMax-M3' `
        -Capabilities @('text.reason', 'quota.read') `
        -SettingsMode 'configPathDirectory'
    $migratedMiniMax.settings['region'] = $miniMaxRegion
    $migratedWorkers['legacy-minimax'] = $migratedMiniMax

    $migratedDocument = [ordered]@{
        schemaVersion = 2
        defaultRoute = $null
        defaultProfile = $null
        workers = $migratedWorkers
        profiles = [ordered]@{}
        routes = [ordered]@{}
    }
    $temporaryPath = Join-Path $destinationDirectory ('.aiw-migrate-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            (ConvertTo-Json -InputObject $migratedDocument -Depth 20),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $validation = New-AiwConfigValidationResult -Path $temporaryPath
        if (-not $validation.ok) {
            return New-AiwConfigMigrationFailure `
                -SourcePath $source.path `
                -DestinationPath $destinationFull `
                -Code 'MIGRATION_OUTPUT_INVALID' `
                -Message 'Generated migration output did not pass v2 validation.'
        }
        [System.IO.File]::Move($temporaryPath, $destinationFull)
    } catch {
        return New-AiwConfigMigrationFailure `
            -SourcePath $source.path `
            -DestinationPath $destinationFull `
            -Code 'MIGRATION_WRITE_FAILED' `
            -Message 'Migration output could not be written safely.'
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return [pscustomobject]@{
        schemaVersion = 2
        ok = $true
        command = 'config'
        action = 'migrate'
        sourcePath = $source.path
        destinationPath = $destinationFull
        configSchemaVersion = 2
        exitCode = 0
        failureKind = $null
        errors = @()
        error = $null
        diagnostics = $null
        warnings = @('Migration copied only reviewed non-secret fields. Review native profile paths and model selections before first run.')
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
        'inventory' {
            $pathProperty = $Request.PSObject.Properties['configPath']
            $outputCommandProperty = $Request.PSObject.Properties['outputCommand']
            $outputCommand = if ($null -eq $outputCommandProperty) {
                'status'
            } else {
                [string]$outputCommandProperty.Value
            }
            return New-AiwInventoryResult `
                -ConfigPath $(if ($null -eq $pathProperty) { $null } else { [string]$pathProperty.Value }) `
                -OutputCommand $outputCommand
        }
        'config.validate' {
            $pathProperty = $Request.PSObject.Properties['configPath']
            if ($null -eq $pathProperty) {
                throw 'Core config request is missing configPath.'
            }
            return New-AiwConfigValidationResult -Path ([string]$pathProperty.Value)
        }
        'config.migrate' {
            $sourceProperty = $Request.PSObject.Properties['configPath']
            if ($null -eq $sourceProperty) {
                throw 'Core migration request is missing configPath.'
            }
            $destinationProperty = $Request.PSObject.Properties['destinationPath']
            $destination = if ($null -eq $destinationProperty) { $null } else { [string]$destinationProperty.Value }
            return Invoke-AiwConfigMigration `
                -SourcePath ([string]$sourceProperty.Value) `
                -DestinationPath $destination
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
