$ErrorActionPreference = 'Stop'
$ownerId = '11111111-1111-4111-8111-111111111111'
$friendId = '22222222-2222-4222-8222-222222222222'
$admin = 'admin@example.invalid'
$friend = 'friend@example.invalid'
$options = @{
    Subscription = 'test-subscription'
    DeploymentAccount = $admin
    ResourceGroup = 'test-resource-group'
}
$deployOptions = @{} + $options
$deployOptions.FoundryAccount = 'test-foundry'
$deployOptions.StorageAccount = 'teststorage'
$deployOptions.Registry = 'testregistry'
$deployOptions.CommunicationName = 'test-communication'
$deployOptions.EmailName = 'test-email'

function New-TestToken {
    param([string]$ObjectId)
    $claims = @{ oid = $ObjectId; tid = 'test-tenant' } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($claims))
    "header.$($payload.TrimEnd('=').Replace('+', '-').Replace('/', '_')).signature"
}

function Write-TestJson {
    param([object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 30
}

function Reset-TestState {
    $script:state = @{
        Invitations = 0; AuthWrites = 0; RuntimeWrites = 0; FailRuntimeOnce = $false
        Directory = @{
            $ownerId = [pscustomobject]@{
                id = $ownerId; userPrincipalName = $admin; mail = $admin; displayName = 'Admin'
            }
        }
        App = [pscustomobject]@{
            id = '/subscriptions/test-subscription/resourceGroups/test/providers/Microsoft.App/containerApps/ca-minecraftgen-web'
            name = 'ca-minecraftgen-web'
            properties = [pscustomobject]@{
                configuration = [pscustomobject]@{
                    ingress = @{ fqdn = 'example.invalid' }
                    secrets = @(@{ name = 'entra-client-secret' })
                }
                template = @{ containers = @(@{
                    env = @(
                        @{ name = 'ALLOWED_USER_IDS'; value = $ownerId },
                        @{ name = 'AZURE_STORAGE_ACCOUNT_URL'; value = 'https://teststorage.blob.core.windows.net' }
                    )
                }) }
            }
        }
        Auth = [pscustomobject]@{
            name = 'current'
            properties = [pscustomobject]@{
                platform = @{ enabled = $true }
                httpSettings = @{ requireHttps = $true }
                identityProviders = @{
                    azureActiveDirectory = @{
                        login = @{ loginParameters = @("login_hint=$admin", 'prompt=select_account') }
                        validation = @{
                            defaultAuthorizationPolicy = @{
                                allowedPrincipals = @{ identities = @($ownerId) }
                            }
                        }
                    }
                }
            }
        }
    }
}

function az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $command = $Arguments[0..1] -join ' '
    $valueOf = { param($Name) $Arguments[[array]::IndexOf($Arguments, $Name) + 1] }
    switch ($command) {
        'account show' {
            Write-TestJson @{ user = @{ name = $admin; type = 'user' }; tenantId = 'test-tenant' }
        }
        'account set' {}
        'account get-access-token' { Write-TestJson @{ accessToken = New-TestToken $ownerId } }
        'ad signed-in-user' { Write-TestJson $state.Directory[$ownerId] }
        'ad user' { Write-TestJson $state.Directory[(& $valueOf '--id')] }
        'containerapp show' { Write-TestJson $state.App }
        'containerapp list' {
            Write-TestJson @($state.App, @{ name = 'ca-minecraftgen-download' })
        }
        'identity show' { Write-TestJson @{ id = 'test-identity'; clientId = 'test-client' } }
        'containerapp env' {
            Write-TestJson @{ id = 'test-environment'; properties = @{ defaultDomain = 'example.invalid' } }
        }
        'containerapp ingress' {}
        'containerapp update' {
            if ((& $valueOf '--name') -eq 'ca-minecraftgen-download') { return }
            if ($state.FailRuntimeOnce) {
                $state.FailRuntimeOnce = $false
                throw 'Simulated runtime update failure'
            }
            $setting = @($Arguments | Where-Object { $_ -like 'ALLOWED_USER_IDS=*' })
            if ($setting.Count -ne 1) { throw 'Expected exactly one runtime allowlist' }
            $state.App.properties.template.containers[0].env[0].value = $setting[0].Substring(17)
            $state.RuntimeWrites++
            Write-TestJson $state.App
        }
        'ad app' {
            if ($Arguments[2] -eq 'list') {
                Write-TestJson @(@{
                    id = 'test-registration'; appId = 'test-application'
                    api = @{ oauth2PermissionScopes = @(@{
                        id = 'test-scope'; value = 'user_impersonation'
                    }) }
                })
            } elseif ($Arguments[2] -ne 'update') {
                throw 'Unexpected app registration operation'
            }
        }
        'ad sp' { Write-TestJson @(@{ id = 'test-service-principal' }) }
        'storage container-rm' { Write-TestJson @{ exists = $true } }
        'rest --method' {
            $method = & $valueOf '--method'
            $url = & $valueOf '--url'
            if ($method -eq 'GET' -and $url -like '*/authConfigs?api-version=*') {
                Write-TestJson @{ value = @($state.Auth) }
            } elseif ($method -eq 'GET' -and $url -like '*/users?*') {
                $decoded = [uri]::UnescapeDataString($url)
                if ($decoded -notmatch "mail eq '((?:[^']|'')*)'") { throw 'Invalid user filter' }
                $email = $Matches[1].Replace("''", "'")
                Write-TestJson @{ value = @($state.Directory.Values |
                    Where-Object { $_.mail -eq $email -or $_.userPrincipalName -eq $email }) }
            } elseif ($method -eq 'POST' -and $url -eq 'https://graph.microsoft.com/v1.0/invitations') {
                $body = Get-Content -LiteralPath ((& $valueOf '--body').Substring(1)) -Raw |
                    ConvertFrom-Json
                if (-not $body.sendInvitationMessage -or
                    $body.inviteRedirectUrl -ne 'https://example.invalid/.auth/login/aad?post_login_redirect_uri=%2F') {
                    throw 'Invitation must send email and link to this application'
                }
                $state.Directory[$friendId] = [pscustomobject]@{
                    id = $friendId; mail = $body.invitedUserEmailAddress
                    userPrincipalName = 'friend_ext@example.invalid'; displayName = 'Friend'
                }
                $state.Invitations++
                Write-TestJson @{ invitedUser = @{ id = $friendId } }
            } elseif ($method -eq 'POST' -and $url -like '*/containers/access-lock/lease?api-version=*') {
                Write-TestJson @{ leaseId = 'test-lease' }
            } elseif ($method -eq 'PUT' -and $url -like '*/authConfigs/current?api-version=*') {
                $body = Get-Content -LiteralPath ((& $valueOf '--body').Substring(1)) -Raw |
                    ConvertFrom-Json
                $state.Auth.properties = $body.properties
                $state.AuthWrites++
                Write-TestJson $state.Auth
            } elseif ($method -ne 'PATCH' -or $url -notlike 'https://graph.microsoft.com/v1.0/applications/*') {
                throw "Unexpected REST operation: $method $url"
            }
        }
        default { throw "Unexpected Azure operation: $command" }
    }
}

function Assert-Membership {
    param([bool]$Expected)
    $ids = $state.Auth.properties.identityProviders.azureActiveDirectory.validation.
        defaultAuthorizationPolicy.allowedPrincipals.identities
    $runtime = $state.App.properties.template.containers[0].env[0].value -split ','
    if (($friendId -in $ids) -ne $Expected -or ($friendId -in $runtime) -ne $Expected -or
        $ownerId -notin $ids -or $ownerId -notin $runtime) {
        throw 'Entra and runtime membership did not match the expected access'
    }
}

Reset-TestState
& "$PSScriptRoot\..\infra\access.ps1" -Action Add -Email $friend -WhatIf @options
if ($state.Invitations -or $state.AuthWrites -or $state.RuntimeWrites) {
    throw 'WhatIf must not send invitations or modify access'
}
Write-Output 'PASS WhatIf makes no directory or application changes'

& "$PSScriptRoot\..\infra\access.ps1" -Action Add -Email $friend @options | Out-Null
Assert-Membership $true
& "$PSScriptRoot\..\infra\access.ps1" -Action Add -Email $friend @options | Out-Null
if ($state.Invitations -ne 1) { throw 'Repeated Add must reuse the invited user' }
$login = $state.Auth.properties.identityProviders.azureActiveDirectory.login.loginParameters
if (@($login | Where-Object { $_ -like 'login_hint=*' }).Count) {
    throw 'Shared access must not preselect the administrator account'
}
Write-Output 'PASS invitation and repeated Add update both controls without duplicate email'

& "$PSScriptRoot\..\infra\deploy.ps1" -Phase Release -SkipBuild -SkipPortal -ImageTag test @deployOptions | Out-Null
Assert-Membership $true
Write-Output 'PASS redeployment preserves invited users in both controls'

$writes = $state.AuthWrites + $state.RuntimeWrites
try {
    & "$PSScriptRoot\..\infra\access.ps1" -Action Remove -UserId $ownerId @options
    throw 'Administrator removal unexpectedly succeeded'
} catch {
    if ($_.Exception.Message -ne 'The deployment administrator cannot be removed.') { throw }
}
if ($state.AuthWrites + $state.RuntimeWrites -ne $writes) { throw 'Owner removal modified access' }
Write-Output 'PASS administrator removal is rejected before modification'

& "$PSScriptRoot\..\infra\access.ps1" -Action Remove -Email $friend @options | Out-Null
Assert-Membership $false
if (-not $state.Directory.ContainsKey($friendId)) { throw 'Revocation must not delete directory users' }
Write-Output 'PASS Remove revokes both controls without deleting the guest'

Reset-TestState
$state.FailRuntimeOnce = $true
try {
    & "$PSScriptRoot\..\infra\access.ps1" -Action Add -Email $friend @options
    throw 'The simulated update failure was ignored'
} catch {
    if ($_.Exception.Message -notlike 'Entra authorization was updated but runtime synchronization failed.*') {
        throw
    }
}
& "$PSScriptRoot\..\infra\access.ps1" -Action Add -Email $friend @options | Out-Null
Assert-Membership $true
if ($state.Invitations -ne 1) { throw 'Repair must not send a duplicate invitation' }
Write-Output 'PASS a partial update is explicit and retry repairs access without reinviting'
