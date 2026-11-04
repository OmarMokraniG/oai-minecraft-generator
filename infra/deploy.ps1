[CmdletBinding()]
param(
    [ValidateSet('Foundation', 'Release', 'All')]
    [string]$Phase = 'All',
    [Parameter(Mandatory)][string]$Subscription,
    [string]$DeploymentAccount,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'swedencentral',
    [Parameter(Mandatory)][string]$FoundryAccount,
    [Parameter(Mandatory)][string]$StorageAccount,
    [Parameter(Mandatory)][string]$Registry,
    [string]$Environment = 'env-minecraftgen',
    [string]$Identity = 'id-minecraftgen-001',
    [string]$DownloadIdentity = 'id-minecraftgen-download-001',
    [string]$AppName = 'ca-minecraftgen-web',
    [string]$DownloadAppName = 'ca-minecraftgen-download',
    [string]$CommunicationName,
    [string]$EmailName,
    [string]$ImageModel = 'gpt-image-2.5-sunburst',
    [string]$ImageVersion = '2026-09-08',
    [string]$VisionModel = 'gpt-6.1-sol',
    [string]$VisionVersion = '2026-09-29',
    [string]$ImageTag = (Get-Date -Format 'yyyyMMddHHmmss'),
    [switch]$SkipBuild,
    [switch]$SkipPortal
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\azure.ps1"

$session = Assert-DeploymentAccount -Subscription $Subscription -DeploymentAccount $DeploymentAccount
$account = $session.Account
$ownerId = $session.User.id
$DeploymentAccount = $session.DeploymentAccount
$subscriptionArgs = @('--subscription', $Subscription)
$groupArgs = @('--resource-group', $ResourceGroup) + $subscriptionArgs
$resourcePrefix = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers"

if (-not $SkipPortal -and (-not $CommunicationName -or -not $EmailName)) {
    throw 'Set globally unique CommunicationName and EmailName values, or use -SkipPortal.'
}

if ($Phase -in @('Foundation', 'All')) {
    foreach ($provider in @(
        'Microsoft.App', 'Microsoft.CognitiveServices', 'Microsoft.ContainerRegistry',
        'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.Network',
        'Microsoft.OperationalInsights', 'Microsoft.Storage'
    )) {
        $registration = Invoke-Azure (@('provider', 'show', '--namespace', $provider) +
            $subscriptionArgs)
        if ($registration.registrationState -ne 'Registered') {
            Invoke-Azure (@('provider', 'register', '--namespace', $provider,
                '--wait') + $subscriptionArgs) | Out-Null
        }
    }
    Invoke-Azure (@('group', 'create', '--name', $ResourceGroup,
        '--location', $Location) + $subscriptionArgs) | Out-Null
    $accounts = @(Invoke-Azure (@('cognitiveservices', 'account', 'list') + $groupArgs))
    if ($FoundryAccount -notin $accounts.name) {
        Invoke-Azure (@('cognitiveservices', 'account', 'create',
            '--name', $FoundryAccount, '--resource-group', $ResourceGroup,
            '--location', $Location, '--kind', 'OpenAI', '--sku', 'S0',
            '--custom-domain', $FoundryAccount) + $subscriptionArgs) | Out-Null
    }
    $storageAccounts = @(Invoke-Azure (@('storage', 'account', 'list') + $groupArgs))
    if ($StorageAccount -notin $storageAccounts.name) {
        Invoke-Azure (@('storage', 'account', 'create',
            '--name', $StorageAccount, '--resource-group', $ResourceGroup,
            '--location', $Location, '--sku', 'Standard_LRS', '--kind', 'StorageV2',
            '--https-only', 'true', '--allow-blob-public-access', 'false',
            '--public-network-access', 'Disabled') + $subscriptionArgs) | Out-Null
    }
    foreach ($model in @(
        @{ Name = $ImageModel; Version = $ImageVersion; Capacity = '1' },
        @{ Name = $VisionModel; Version = $VisionVersion; Capacity = '10' }
    )) {
        $deployments = @(Invoke-Azure (@('cognitiveservices', 'account', 'deployment', 'list',
            '--name', $FoundryAccount) + $groupArgs))
        $existing = @($deployments | Where-Object { $_.name -eq $model.Name })
        if ($existing.Count -eq 0 -or $existing[0].properties.model.version -ne $model.Version) {
            $capacity = if ($existing.Count) { [string]$existing[0].sku.capacity } else { $model.Capacity }
            Write-Host "Deploying model $($model.Name) version $($model.Version)"
            Invoke-Azure (@('cognitiveservices', 'account', 'deployment', 'create',
                '--name', $FoundryAccount, '--deployment-name', $model.Name,
                '--model-name', $model.Name, '--model-version', $model.Version,
                '--model-format', 'OpenAI', '--sku-name', 'GlobalStandard',
                '--sku-capacity', $capacity) + $groupArgs) | Out-Null
        }
    }
    $identities = @(Invoke-Azure (@('identity', 'list') + $groupArgs))
    if ($Identity -notin $identities.name) {
        Invoke-Azure (@('identity', 'create', '--name', $Identity,
            '--location', $Location) + $groupArgs) | Out-Null
    }
    $managedIdentity = Invoke-Azure (@('identity', 'show', '--name', $Identity) + $groupArgs)
    Grant-Role "$resourcePrefix/Microsoft.CognitiveServices/accounts/$FoundryAccount" `
        $managedIdentity.principalId 'Cognitive Services OpenAI User'
    Grant-Role "$resourcePrefix/Microsoft.Storage/storageAccounts/$StorageAccount" `
        $managedIdentity.principalId 'Storage Blob Data Contributor'

    Invoke-Azure (@('storage', 'account', 'update', '--name', $StorageAccount,
        '--public-network-access', 'Disabled', '--allow-blob-public-access', 'false') +
        $groupArgs) | Out-Null

    $vnetName = 'vnet-minecraftgen-001'
    $vnets = @(Invoke-Azure (@('network', 'vnet', 'list') + $groupArgs))
    if ($vnetName -notin $vnets.name) {
        Invoke-Azure (@('network', 'vnet', 'create', '--name', $vnetName,
            '--location', $Location, '--address-prefixes', '10.87.0.0/16',
            '--subnet-name', 'aca', '--subnet-prefixes', '10.87.0.0/23') + $groupArgs) |
            Out-Null
        Invoke-Azure (@('network', 'vnet', 'subnet', 'update', '--vnet-name', $vnetName,
            '--name', 'aca', '--delegations', 'Microsoft.App/environments') + $groupArgs) |
            Out-Null
        Invoke-Azure (@('network', 'vnet', 'subnet', 'create', '--vnet-name', $vnetName,
            '--name', 'private-endpoints', '--address-prefixes', '10.87.2.0/27',
            '--private-endpoint-network-policies', 'Disabled') + $groupArgs) | Out-Null
    }
    $zone = 'privatelink.blob.core.windows.net'
    $zones = @(Invoke-Azure (@('network', 'private-dns', 'zone', 'list') + $groupArgs))
    if ($zone -notin $zones.name) {
        Invoke-Azure (@('network', 'private-dns', 'zone', 'create', '--name', $zone) +
            $groupArgs) | Out-Null
        Invoke-Azure (@('network', 'private-dns', 'link', 'vnet', 'create',
            '--zone-name', $zone, '--name', 'minecraft-vnet',
            '--virtual-network', "$resourcePrefix/Microsoft.Network/virtualNetworks/$vnetName",
            '--registration-enabled', 'false') + $groupArgs) | Out-Null
    }
    $endpoints = @(Invoke-Azure (@('network', 'private-endpoint', 'list') + $groupArgs))
    if ('pe-minecraft-blob' -notin $endpoints.name) {
        Invoke-Azure (@('network', 'private-endpoint', 'create', '--name', 'pe-minecraft-blob',
            '--location', $Location, '--vnet-name', $vnetName, '--subnet', 'private-endpoints',
            '--private-connection-resource-id',
            "$resourcePrefix/Microsoft.Storage/storageAccounts/$StorageAccount",
            '--group-id', 'blob', '--connection-name', 'minecraft-blob') + $groupArgs) | Out-Null
        Invoke-Azure (@('network', 'private-endpoint', 'dns-zone-group', 'create',
            '--endpoint-name', 'pe-minecraft-blob', '--name', 'default',
            '--private-dns-zone', "$resourcePrefix/Microsoft.Network/privateDnsZones/$zone",
            '--zone-name', 'blob') + $groupArgs) | Out-Null
    }

    $registries = @(Invoke-Azure (@('acr', 'list') + $groupArgs))
    if ($Registry -notin $registries.name) {
        Invoke-Azure (@('acr', 'create', '--name', $Registry, '--sku', 'Basic',
            '--admin-enabled', 'false', '--location', $Location) + $groupArgs) | Out-Null
    }
    Grant-Role "$resourcePrefix/Microsoft.ContainerRegistry/registries/$Registry" `
        $managedIdentity.principalId 'AcrPull'
    if ($DownloadIdentity -notin $identities.name) {
        Invoke-Azure (@('identity', 'create', '--name', $DownloadIdentity,
            '--location', $Location) + $groupArgs) | Out-Null
    }
    $downloadIdentityResource = Invoke-Azure (@('identity', 'show', '--name', $DownloadIdentity) +
        $groupArgs)
    Grant-Role "$resourcePrefix/Microsoft.ContainerRegistry/registries/$Registry" `
        $downloadIdentityResource.principalId 'AcrPull'

    $environments = @(Invoke-Azure (@('containerapp', 'env', 'list') + $groupArgs))
    if ($Environment -notin $environments.name) {
        $workspace = Invoke-Azure (@('monitor', 'log-analytics', 'workspace', 'create',
            '--workspace-name', 'law-minecraftgen-001', '--location', $Location,
            '--retention-time', '30', '--quota', '1') + $groupArgs)
        $workspaceKeys = Invoke-Azure (@('monitor', 'log-analytics', 'workspace', 'get-shared-keys',
            '--workspace-name', 'law-minecraftgen-001') + $groupArgs)
        Invoke-Azure (@('containerapp', 'env', 'create', '--name', $Environment,
            '--location', $Location, '--logs-workspace-id', $workspace.customerId,
            '--logs-workspace-key', $workspaceKeys.primarySharedKey,
            '--infrastructure-subnet-resource-id',
            "$resourcePrefix/Microsoft.Network/virtualNetworks/$vnetName/subnets/aca",
            '--environment-mode', 'WorkloadProfiles') + $groupArgs) | Out-Null
        $workspaceKeys = $null
    }
    if (-not $SkipPortal) {
        & "$PSScriptRoot\portal.ps1" -Phase Foundation -Subscription $Subscription `
            -DeploymentAccount $DeploymentAccount -ResourceGroup $ResourceGroup `
            -Location $Location -Registry $Registry -Environment $Environment -AppName $AppName `
            -StorageAccount $StorageAccount -CommunicationName $CommunicationName -EmailName $EmailName
    }
}

if ($Phase -eq 'Foundation') {
    Write-Host 'Foundation provisioning completed.'
    return
}

$managedIdentity = Invoke-Azure (@('identity', 'show', '--name', $Identity) + $groupArgs)
$downloadIdentityResource = Invoke-Azure (@('identity', 'show', '--name', $DownloadIdentity) +
    $groupArgs)
$environmentResource = Invoke-Azure (@('containerapp', 'env', 'show',
    '--name', $Environment) + $groupArgs)
$image = "$Registry.azurecr.io/minecraft-generator:$ImageTag"
$url = "https://$AppName.$($environmentResource.properties.defaultDomain)"
$downloadUrl = "https://$DownloadAppName.$($environmentResource.properties.defaultDomain)"
$portalUrl = "https://ca-minecraftgen-admin.$($environmentResource.properties.defaultDomain)"
$appVariables = @(
    "AZURE_CLIENT_ID=$($managedIdentity.clientId)",
    "AZURE_OPENAI_ENDPOINT=https://$FoundryAccount.openai.azure.com",
    "AZURE_IMAGE_DEPLOYMENT=$ImageModel",
    "AZURE_VISION_DEPLOYMENT=$VisionModel",
    "AZURE_STORAGE_ACCOUNT_URL=https://$StorageAccount.blob.core.windows.net",
    "PUBLIC_DOWNLOAD_BASE_URL=$downloadUrl",
    'REQUIRE_AUTH=true'
)
if (-not $SkipPortal) {
    $appVariables += @("ADMIN_USER_ID=$ownerId", "ADMIN_PORTAL_URL=$portalUrl")
}

if (-not $SkipBuild) {
    Push-Location $root
    try {
        Invoke-Azure (@('acr', 'build', '--no-logs', '--registry', $Registry,
            '--image', "minecraft-generator:$ImageTag", '--file', 'Dockerfile', '.') +
            $subscriptionArgs) | Out-Null
    } finally {
        Pop-Location
    }
}

$apps = @(Invoke-Azure (@('containerapp', 'list') + $groupArgs))
$allowedUserIds = @($ownerId)
$existingWeb = @($apps | Where-Object { $_.name -eq $AppName })
if ($existingWeb.Count -eq 1) {
    $existingAuth = Get-ContainerAppAuth -ResourceId $existingWeb[0].id
    if ($null -ne $existingAuth) {
        $allowedUserIds = @(Get-AccessUserIds -Auth $existingAuth -OwnerId $ownerId)
    }
}
if ($DownloadAppName -notin $apps.name) {
    Invoke-Azure (@('containerapp', 'create', '--name', $DownloadAppName,
        '--environment', $environmentResource.id, '--image', $image,
        '--registry-server', "$Registry.azurecr.io",
        '--registry-identity', $downloadIdentityResource.id,
        '--user-assigned', $downloadIdentityResource.id,
        '--ingress', 'external', '--target-port', '8000', '--transport', 'http',
        '--cpu', '0.25', '--memory', '0.5Gi', '--min-replicas', '0', '--max-replicas', '1',
        '--command', 'python', '--args', 'download_app.py',
        '--env-vars', "AZURE_STORAGE_ACCOUNT_URL=https://$StorageAccount.blob.core.windows.net",
        'APP_HEALTH_URL=http://127.0.0.1:8000/health') +
        $groupArgs) | Out-Null
} else {
    Invoke-Azure (@('containerapp', 'update', '--name', $DownloadAppName, '--image', $image) +
        $groupArgs) | Out-Null
}
if ($AppName -notin $apps.name) {
    Invoke-Azure (@('containerapp', 'create', '--name', $AppName,
        '--environment', $environmentResource.id, '--image', $image,
        '--registry-server', "$Registry.azurecr.io",
        '--registry-identity', $managedIdentity.id, '--user-assigned', $managedIdentity.id,
        '--ingress', 'internal', '--target-port', '8501',
        '--transport', 'http', '--cpu', '1.0', '--memory', '2Gi',
        '--min-replicas', '0', '--max-replicas', '1',
        '--env-vars') + $appVariables + "ALLOWED_USER_IDS=$ownerId" + $groupArgs) | Out-Null
}

$registrations =@(Invoke-Azure @('ad', 'app', 'list', '--display-name', 'minecraft-generator-web'))
if ($registrations.Count -gt 1) {
    throw 'Multiple matching Entra app registrations; resolve before deploying.'
}
if ($registrations.Count -eq 0) {
    $registration = Invoke-Azure @('ad', 'app', 'create', '--display-name',
        'minecraft-generator-web', '--sign-in-audience', 'AzureADMyOrg',
        '--web-redirect-uris', "$url/.auth/login/aad/callback",
        '--enable-id-token-issuance', 'true')
} else {
    $registration = $registrations[0]
    $redirects = @($registration.web.redirectUris) + @("$url/.auth/login/aad/callback")
    if (-not $SkipPortal) {
        $redirects += "$portalUrl/.auth/login/aad/callback"
    }
    $redirects = @($redirects | Where-Object { $_ } | Sort-Object -Unique)
    Invoke-Azure (@('ad', 'app', 'update', '--id', $registration.id,
        '--web-redirect-uris') + $redirects) | Out-Null
}
$principals = @(Invoke-Azure @('ad', 'sp', 'list',
    '--filter', "appId eq '$($registration.appId)'"))
if ($principals.Count -eq 0) {
    Invoke-Azure @('ad', 'sp', 'create', '--id', $registration.appId) | Out-Null
}

$existingScope = @($registration.api.oauth2PermissionScopes |
    Where-Object { $_.value -eq 'user_impersonation' })
$scopeId = if ($existingScope.Count -eq 1) {
    $existingScope[0].id
} else {
    [guid]::NewGuid().ToString()
}
$manifest = @{
    identifierUris = @("api://$($registration.appId)")
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(@{
            id = $scopeId; value = 'user_impersonation'; type = 'User'; isEnabled = $true
            adminConsentDisplayName = 'Access Minecraft Generator'
            adminConsentDescription = 'Access Minecraft Generator as the signed-in user.'
            userConsentDisplayName = 'Access Minecraft Generator'
            userConsentDescription = 'Access Minecraft Generator as you.'
        })
    }
}
$manifestFile = Join-Path ([System.IO.Path]::GetTempPath()) "minecraft-manifest-$PID.json"
try {
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestFile -Encoding utf8
    Invoke-Azure @('rest', '--method', 'PATCH',
        '--url', "https://graph.microsoft.com/v1.0/applications/$($registration.id)",
        '--body', "@$manifestFile") | Out-Null
    # Graph must persist the scope before it can validate client preauthorization.
    @{
        api = @{
            preAuthorizedApplications = @(@{
                appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
                delegatedPermissionIds = @($scopeId)
            })
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestFile -Encoding utf8
    Invoke-Azure @('rest', '--method', 'PATCH',
        '--url', "https://graph.microsoft.com/v1.0/applications/$($registration.id)",
        '--body', "@$manifestFile") | Out-Null
} finally {
    Remove-Item -LiteralPath $manifestFile -ErrorAction SilentlyContinue
}

$deployedApp = Invoke-Azure (@('containerapp', 'show', '--name', $AppName) + $groupArgs)
if ('entra-client-secret' -notin $deployedApp.properties.configuration.secrets.name) {
    $credential = Invoke-Azure @('ad', 'app', 'credential', 'reset',
        '--id', $registration.id, '--append', '--display-name', 'Container Apps login',
        '--years', '1')
    Invoke-Azure (@('containerapp', 'secret', 'set', '--name', $AppName, '--secrets',
        "entra-client-secret=$($credential.password)") + $groupArgs) | Out-Null
    $credential = $null
}

$auth = @{
    properties = @{
        platform = @{ enabled = $true }
        globalValidation = @{
            unauthenticatedClientAction = 'RedirectToLoginPage'
            redirectToProvider = 'aad'
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled = $true
                login = @{
                    loginParameters = @(Get-AccountSelectionParameters `
                        -UserIds $allowedUserIds -DeploymentAccount $DeploymentAccount)
                }
                registration = @{
                    clientId = $registration.appId
                    clientSecretSettingName = 'entra-client-secret'
                    openIdIssuer = "https://login.microsoftonline.com/$($account.tenantId)/v2.0"
                }
                validation = @{
                    allowedAudiences = @($registration.appId, "api://$($registration.appId)")
                    defaultAuthorizationPolicy = @{
                        allowedApplications = @(
                            $registration.appId,
                            '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
                        )
                        allowedPrincipals = @{ identities = $allowedUserIds }
                    }
                }
            }
        }
        login = @{ tokenStore = @{ enabled = $false } }
        httpSettings = @{ requireHttps = $true }
    }
}
$webId = "$resourcePrefix/Microsoft.App/containerApps/$AppName"
$lockArgs = @('--storage-account', $StorageAccount, '--name', $accessLockContainer) + $groupArgs
if (-not (Invoke-Azure (@('storage', 'container-rm', 'exists') + $lockArgs)).exists) {
    Invoke-Azure (@('storage', 'container-rm', 'create') + $lockArgs) | Out-Null
}
$lock = Enter-AccessLock -LockId (Get-AccessLockId -StorageId (
    "$resourcePrefix/Microsoft.Storage/storageAccounts/$StorageAccount"
))
try {
    $currentAuth = Get-ContainerAppAuth -ResourceId $webId
    if ($null -ne $currentAuth) {
        $allowedUserIds = @(Get-AccessUserIds -Auth $currentAuth -OwnerId $ownerId)
    }
    $aad = $auth.properties.identityProviders.azureActiveDirectory
    $aad.login.loginParameters = @(Get-AccountSelectionParameters `
        -UserIds $allowedUserIds -DeploymentAccount $DeploymentAccount)
    $aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities = $allowedUserIds
    Invoke-AzureJson -Method PUT -Body $auth -Url (
        "https://management.azure.com$webId/authConfigs/current?api-version=2025-01-01"
    ) | Out-Null
    Invoke-Azure (@('containerapp', 'update', '--name', $AppName, '--image', $image,
        '--min-replicas', '0', '--max-replicas', '1', '--set-env-vars') + $appVariables +
        "ALLOWED_USER_IDS=$($allowedUserIds -join ',')" + $groupArgs) | Out-Null
} finally {
    Exit-AccessLock -Lock $lock
}
Invoke-Azure (@('containerapp', 'ingress', 'enable', '--name', $AppName,
    '--type', 'external', '--target-port', '8501', '--transport', 'http') + $groupArgs) |
    Out-Null
if (-not $SkipPortal) {
    & "$PSScriptRoot\portal.ps1" -Phase Release -Subscription $Subscription `
        -DeploymentAccount $DeploymentAccount -ResourceGroup $ResourceGroup `
        -Location $Location -Registry $Registry -Environment $Environment `
        -AppName $AppName -ImageTag $ImageTag -StorageAccount $StorageAccount `
        -CommunicationName $CommunicationName -EmailName $EmailName
}

[ordered]@{
    url = $url
    image = $image
    imageModel = $ImageModel
    visionModel = $VisionModel
    identityId = $managedIdentity.id
    loginAppId = $registration.appId
    downloadUrl = $downloadUrl
} | ConvertTo-Json
