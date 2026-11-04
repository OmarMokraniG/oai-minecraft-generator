$accessLockContainer = 'access-lock'

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

function Get-AzureTokenClaims {
    param([string]$Subscription)
    $token = (Invoke-Azure @('account', 'get-access-token', '--subscription', $Subscription)).accessToken
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight([math]::Ceiling($payload.Length / 4) * 4, '=')
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Assert-DeploymentAccount {
    param([string]$Subscription, [string]$DeploymentAccount)
    $account = Invoke-Azure @('account', 'show', '--subscription', $Subscription)
    if ($account.user.type -ne 'user' -or -not $account.user.name) {
        throw 'Sign in to Azure CLI as a Microsoft Entra user before deploying.'
    }
    if ($DeploymentAccount -and $account.user.name -ine $DeploymentAccount) {
        throw "The signed-in Azure CLI user does not match $DeploymentAccount."
    }
    Invoke-Azure @('account', 'set', '--subscription', $Subscription) | Out-Null
    $user = Invoke-Azure @('ad', 'signed-in-user', 'show')
    $claims = Get-AzureTokenClaims -Subscription $Subscription
    if ($claims.tid -ine $account.tenantId -or $claims.oid -ine $user.id) {
        throw 'The Microsoft Graph session does not match the signed-in Azure CLI user.'
    }
    [pscustomobject]@{
        Account = $account
        User = $user
        DeploymentAccount = $account.user.name
    }
}

function Get-AccessLockId {
    param([string]$StorageId)
    "$StorageId/blobServices/default/containers/$accessLockContainer"
}

function Enter-AccessLock {
    param([string]$LockId)
    $url = "https://management.azure.com$LockId/lease?api-version=2023-05-01"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "minecraft-$([guid]::NewGuid()).json"
    try {
        @{ action = 'Acquire'; leaseDuration = 60 } | ConvertTo-Json |
            Set-Content -LiteralPath $file -Encoding utf8
        $deadline = (Get-Date).AddMinutes(5)
        while ($true) {
            $result = & az rest --method POST --url $url --body "@$file" --only-show-errors --output json 2>&1
            if ($LASTEXITCODE -eq 0) {
                break
            }
            if ("$result" -notlike '*Conflict(*') {
                throw "Could not lock access updates. Run deploy.ps1 if this deployment predates the lock. $result"
            }
            if ((Get-Date) -ge $deadline) {
                throw 'Timed out waiting for another access update to finish.'
            }
            Start-Sleep -Seconds 5
        }
        $leaseId = (($result -join "`n") | ConvertFrom-Json).leaseId
        @{ action = 'Renew'; leaseId = $leaseId } | ConvertTo-Json |
            Set-Content -LiteralPath $file -Encoding utf8
    } catch {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        throw
    }
    $renewal = Start-ThreadJob -ArgumentList $url, $file -ScriptBlock {
        param($Url, $File)
        while ($true) {
            Start-Sleep -Seconds 20
            & az rest --method POST --url $Url --body "@$File" --only-show-errors --output none
        }
    }
    [pscustomobject]@{ Url = $url; LeaseId = $leaseId; File = $file; Renewal = $renewal }
}

function Exit-AccessLock {
    param([object]$Lock)
    Remove-Job -Job $Lock.Renewal -Force
    Remove-Item -LiteralPath $Lock.File -ErrorAction SilentlyContinue
    try {
        Invoke-AzureJson -Method POST -Url $Lock.Url -Body @{
            action = 'Release'; leaseId = $Lock.LeaseId
        } | Out-Null
    } catch {
        Write-Warning 'The access lock expired before it was released. Confirm the result with List.'
    }
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
