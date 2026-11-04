[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('List', 'Add', 'Remove')]
    [string]$Action = 'List',
    [string]$Email,
    [string]$UserId,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$DeploymentAccount,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$AppName = 'ca-minecraftgen-web'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
. "$PSScriptRoot\azure.ps1"

if ($Email) {
    $address = [System.Net.Mail.MailAddress]::new($Email)
    if ($address.Address -ne $Email) {
        throw 'Supply only an email address, without a display name.'
    }
}
if (($Action -eq 'Add' -and (-not $Email -or $UserId)) -or
    ($Action -eq 'Remove' -and ([bool]$Email -eq [bool]$UserId)) -or
    ($Action -eq 'List' -and ($Email -or $UserId))) {
    throw 'Use Add -Email, Remove -Email or -UserId, or List without a user.'
}
if ($UserId) {
    $UserId = ([guid]$UserId).ToString()
}

$session = Assert-DeploymentAccount -Subscription $Subscription -DeploymentAccount $DeploymentAccount
$ownerId = $session.User.id
$DeploymentAccount = $session.DeploymentAccount
$groupArgs = @('--resource-group', $ResourceGroup, '--subscription', $Subscription)
$app = Invoke-Azure (@('containerapp', 'show', '--name', $AppName) + $groupArgs)
$auth = Get-ContainerAppAuth -ResourceId $app.id
if ($null -eq $auth -or -not $auth.properties.platform.enabled) {
    throw 'Deploy and enable application authentication before managing access.'
}
$allowed = @(Get-AccessUserIds -Auth $auth -OwnerId $ownerId)
$url = "https://$($app.properties.configuration.ingress.fqdn)"
$runtimeIds = @((($app.properties.template.containers[0].env |
    Where-Object { $_.name -eq 'ALLOWED_USER_IDS' }).value -split ',') | Sort-Object -Unique)
if (($runtimeIds -join ',') -ne ($allowed -join ',')) {
    Write-Warning 'Runtime access differs from Entra authorization. Add/Remove will synchronize it.'
}

if ($Action -eq 'List') {
    $directory = Invoke-AzureJson -Method POST `
        -Url 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body @{
            ids = $allowed; types = @('user')
        }
    foreach ($id in $allowed) {
        $user = $directory.value | Where-Object { $_.id -eq $id } | Select-Object -First 1
        [pscustomobject]@{
            UserId = $id
            Name = $(if ($user) { $user.displayName } else { 'Deleted directory account' })
            Email = $(if ($user.mail) { $user.mail } else { $user.userPrincipalName })
            Administrator = ($id -eq $ownerId)
            RuntimeAllowed = ($id -in $runtimeIds)
            DirectoryMissing = ($null -eq $user)
        }
    }
    return
}

$user = $null
if ($Email) {
    $literal = $Email.Replace("'", "''")
    $filter = [uri]::EscapeDataString("mail eq '$literal' or userPrincipalName eq '$literal'")
    $users = Invoke-Azure @('rest', '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/users?`$filter=$filter")
    if (@($users.value).Count -gt 1 -or $users.'@odata.nextLink') {
        throw 'Multiple directory users match that email. Resolve the duplicate identities first.'
    }
    if (@($users.value).Count -eq 1) {
        $user = $users.value[0]
        $UserId = $user.id
    } elseif ($Action -eq 'Remove') {
        throw 'No directory user matches that email. Use the user ID from List for deleted users.'
    }
}
if ($Action -eq 'Remove' -and $UserId -eq $ownerId) {
    throw 'The deployment administrator cannot be removed.'
}
if (-not $PSCmdlet.ShouldProcess(
    "$AppName / $(if ($Email) { $Email } else { $UserId })",
    "$(if ($Action -eq 'Add') { 'Invite if needed and grant access' } else { 'Revoke access' })"
)) {
    return
}

$storageUrl = ($app.properties.template.containers[0].env |
    Where-Object { $_.name -eq 'AZURE_STORAGE_ACCOUNT_URL' }).value
if (-not $storageUrl) {
    throw 'The application has no storage account configured. Run deploy.ps1 before managing access.'
}
$storageAccount = ([uri]$storageUrl).Host.Split('.')[0]
$lock = Enter-AccessLock -LockId (Get-AccessLockId -StorageId (
    "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount"
))
try {
    $auth = Get-ContainerAppAuth -ResourceId $app.id
    $allowed = @(Get-AccessUserIds -Auth $auth -OwnerId $ownerId)
    if ($Action -eq 'Add') {
        if ($null -eq $user) {
            $invitation = Invoke-AzureJson -Method POST `
                -Url 'https://graph.microsoft.com/v1.0/invitations' -Body @{
                    invitedUserEmailAddress = $Email
                    inviteRedirectUrl = "$url/.auth/login/aad?post_login_redirect_uri=%2F"
                    sendInvitationMessage = $true
                }
            $UserId = $invitation.invitedUser.id
            if (-not $UserId) {
                throw 'The invitation returned no user ID; no application access was changed.'
            }
        }
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($UserId, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
            throw 'The directory returned an invalid user ID; no application access was changed.'
        }
        $UserId = $parsedId.ToString()
        $allowed = @($allowed + $UserId | Sort-Object -Unique)
    } else {
        $allowed = @($allowed | Where-Object { $_ -ne $UserId })
    }

    $aad = $auth.properties.identityProviders.azureActiveDirectory
    $aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities = $allowed
    if ($null -eq $aad.login) {
        $aad | Add-Member -NotePropertyName login -NotePropertyValue ([pscustomobject]@{})
    }
    $aad.login | Add-Member -NotePropertyName loginParameters -Force -NotePropertyValue (
        @(Get-AccountSelectionParameters -UserIds $allowed -DeploymentAccount $DeploymentAccount)
    )
    Invoke-AzureJson -Method PUT -Body @{ properties = $auth.properties } -Url (
        "https://management.azure.com$($app.id)/authConfigs/current?api-version=2025-01-01"
    ) | Out-Null
    try {
        Invoke-Azure (@('containerapp', 'update', '--name', $AppName,
            '--set-env-vars', "ALLOWED_USER_IDS=$($allowed -join ',')") + $groupArgs) | Out-Null
    } catch {
        throw "Entra authorization was updated but runtime synchronization failed. Re-run the same command to repair it. $($_.Exception.Message)"
    }

    $updatedAuth = Get-ContainerAppAuth -ResourceId $app.id
    $updatedIds = @(Get-AccessUserIds -Auth $updatedAuth -OwnerId $ownerId)
    $updatedApp = Invoke-Azure (@('containerapp', 'show', '--name', $AppName) + $groupArgs)
    $updatedRuntime = @((($updatedApp.properties.template.containers[0].env |
        Where-Object { $_.name -eq 'ALLOWED_USER_IDS' }).value -split ',') | Sort-Object -Unique)
    if (($updatedIds -join ',') -ne ($allowed -join ',') -or
        ($updatedRuntime -join ',') -ne ($allowed -join ',')) {
        throw 'Access verification failed. Another administrator may have changed access; inspect List.'
    }
} finally {
    Exit-AccessLock -Lock $lock
}
[pscustomobject]@{
    Action = $Action
    UserId = $UserId
    Email = $Email
    Application = $url
    Status = 'Verified in Entra and Container Apps'
}
