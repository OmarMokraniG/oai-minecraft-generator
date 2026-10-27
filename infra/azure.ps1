function Invoke-Azure {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure command failed: $($Arguments[0..1] -join ' ')"
    }
    if ($result) {
        ($result -join "`n") | ConvertFrom-Json
    }
}

function Invoke-AzureJson {
    param([string]$Method, [string]$Url, [object]$Body)
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "minecraft-$([guid]::NewGuid()).json"
    try {
        $Body | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8
        Invoke-Azure @('rest', '--method', $Method, '--url', $Url, '--body', "@$file")
    } finally {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file
        }
    }
}

function Assert-DeploymentAccount {
    param([string]$Subscription, [string]$DeploymentAccount)
    $account = Invoke-Azure @('account', 'show', '--subscription', $Subscription)
    if ($account.user.type -ne 'user' -or $account.user.name -ine $DeploymentAccount) {
        throw "Sign in to Azure CLI as $DeploymentAccount in tenant $($account.tenantId) before deploying."
    }
    Invoke-Azure @('account', 'set', '--subscription', $Subscription) | Out-Null
    $user = Invoke-Azure @('ad', 'signed-in-user', 'show')
    if ($user.userPrincipalName -ine $DeploymentAccount) {
        throw 'The Microsoft Graph session does not match the configured deployment account.'
    }
    [pscustomobject]@{ Account = $account; User = $user }
}

function Get-ContainerAppAuth {
    param([string]$ResourceId)
    $configs = Invoke-Azure @('rest', '--method', 'GET', '--url',
        "https://management.azure.com$ResourceId/authConfigs?api-version=2025-01-01")
    $current = @($configs.value | Where-Object { $_.name -eq 'current' })
    if ($current.Count -gt 1) {
        throw 'Multiple current authentication configurations were returned.'
    }
    if ($current.Count -eq 1) {
        $current[0]
    }
}

function Get-AccessUserIds {
    param([object]$Auth, [string]$OwnerId)
    $values = $Auth.properties.identityProviders.azureActiveDirectory.validation.
        defaultAuthorizationPolicy.allowedPrincipals.identities
    $ids = @($values | ForEach-Object {
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string]$_, [ref]$id) -or $id -eq [guid]::Empty) {
            throw 'The authentication allowlist contains an invalid user ID.'
        }
        $id.ToString()
    } | Sort-Object -Unique)
    if ($ids.Count -eq 0 -or $OwnerId -notin $ids) {
        throw 'The authentication allowlist must include the deployment administrator.'
    }
    $ids
}

function Get-AccountSelectionParameters {
    param([string[]]$UserIds, [string]$DeploymentAccount)
    'prompt=select_account'
    if ($UserIds.Count -eq 1) {
        "login_hint=$DeploymentAccount"
    }
}

function Grant-Role {
    param([string]$Scope, [string]$Principal, [string]$Role)
    $existing = @(Invoke-Azure @('role', 'assignment', 'list',
        '--assignee-object-id', $Principal, '--scope', $Scope,
        '--role', $Role, '--subscription', $Subscription))
    if ($existing.Count -eq 0) {
        Invoke-Azure @('role', 'assignment', 'create',
            '--assignee-object-id', $Principal, '--assignee-principal-type', 'ServicePrincipal',
            '--scope', $Scope, '--role', $Role, '--subscription', $Subscription) | Out-Null
    }
}
