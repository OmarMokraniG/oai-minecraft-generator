[CmdletBinding()]
param(
    [ValidateSet('Foundation', 'Release', 'All')]
    [string]$Phase = 'All',
    [string]$Subscription = 'ae027918-9050-4f80-ae04-199387d603ad',
    [string]$ResourceGroup = 'rg-minecraftgenerator-001',
    [string]$Location = 'swedencentral',
    [string]$FoundryAccount = 'f-minecraft-001',
    [string]$StorageAccount = 'staminecraftgen',
    [string]$Registry = 'crminecraftgenom4',
    [string]$Environment = 'env-minecraftgen-001',
    [string]$Identity = 'id-minecraftgen-001',
    [string]$AppName = 'ca-minecraftgen-001',
    [string]$ImageModel = 'gpt-image-2.5-sunburst',
    [string]$ImageVersion = '2026-09-08',
    [string]$VisionModel = 'gpt-6.1-sol',
    [string]$VisionVersion = '2026-09-29',
    [string]$ImageTag = (Get-Date -Format 'yyyyMMddHHmmss')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$root = Split-Path $PSScriptRoot -Parent

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

$account = Invoke-Azure @('account', 'show', '--subscription', $Subscription)
$signedIn = Invoke-Azure @('ad', 'signed-in-user', 'show')
$ownerId = $signedIn.id
$subscriptionArgs = @('--subscription', $Subscription)
$groupArgs = @('--resource-group', $ResourceGroup) + $subscriptionArgs
$resourcePrefix = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers"

if ($Phase -in @('Foundation', 'All')) {
    foreach ($model in @(
        @{ Name = $ImageModel; Version = $ImageVersion; Capacity = '1' },
        @{ Name = $VisionModel; Version = $VisionVersion; Capacity = '10' }
    )) {
        $deployments = @(Invoke-Azure (@('cognitiveservices', 'account', 'deployment', 'list',
            '--name', $FoundryAccount) + $groupArgs))
        if ($model.Name -notin $deployments.name) {
            Write-Host "Deploying model $($model.Name)"
            Invoke-Azure (@('cognitiveservices', 'account', 'deployment', 'create',
                '--name', $FoundryAccount, '--deployment-name', $model.Name,
                '--model-name', $model.Name, '--model-version', $model.Version,
                '--model-format', 'OpenAI', '--sku-name', 'GlobalStandard',
                '--sku-capacity', $model.Capacity) + $groupArgs) | Out-Null
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

    # QR downloads require a reachable endpoint, not anonymous containers or account keys.
    Invoke-Azure (@('storage', 'account', 'update', '--name', $StorageAccount,
        '--public-network-access', 'Enabled', '--allow-blob-public-access', 'false') +
        $groupArgs) | Out-Null

    $registries = @(Invoke-Azure (@('acr', 'list') + $groupArgs))
    if ($Registry -notin $registries.name) {
        Invoke-Azure (@('acr', 'create', '--name', $Registry, '--sku', 'Basic',
            '--admin-enabled', 'false', '--location', $Location) + $groupArgs) | Out-Null
    }
    Grant-Role "$resourcePrefix/Microsoft.ContainerRegistry/registries/$Registry" `
        $managedIdentity.principalId 'AcrPull'

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
            '--environment-mode', 'WorkloadProfiles') + $groupArgs) | Out-Null
        $workspaceKeys = $null
    }
}

if ($Phase -eq 'Foundation') {
    Write-Host 'Foundation provisioning completed.'
    return
}

$managedIdentity = Invoke-Azure (@('identity', 'show', '--name', $Identity) + $groupArgs)
$environmentResource = Invoke-Azure (@('containerapp', 'env', 'show',
    '--name', $Environment) + $groupArgs)
$image = "$Registry.azurecr.io/minecraft-generator:$ImageTag"
$url = "https://$AppName.$($environmentResource.properties.defaultDomain)"
$appVariables = @(
    "AZURE_CLIENT_ID=$($managedIdentity.clientId)",
    "AZURE_OPENAI_ENDPOINT=https://$FoundryAccount.openai.azure.com",
    "AZURE_IMAGE_DEPLOYMENT=$ImageModel",
    "AZURE_VISION_DEPLOYMENT=$VisionModel",
    "AZURE_STORAGE_ACCOUNT_URL=https://$StorageAccount.blob.core.windows.net",
    'REQUIRE_AUTH=true',
    "ALLOWED_USER_IDS=$ownerId"
)

Push-Location $root
try {
    Invoke-Azure (@('acr', 'build', '--no-logs', '--registry', $Registry,
        '--image', "minecraft-generator:$ImageTag", '--file', 'Dockerfile', '.') +
        $subscriptionArgs) | Out-Null
} finally {
    Pop-Location
}

$apps = @(Invoke-Azure (@('containerapp', 'list') + $groupArgs))
if ($AppName -notin $apps.name) {
    Invoke-Azure (@('containerapp', 'create', '--name', $AppName,
        '--environment', $environmentResource.id, '--image', $image,
        '--registry-server', "$Registry.azurecr.io",
        '--registry-identity', $managedIdentity.id, '--user-assigned', $managedIdentity.id,
        '--ingress', 'internal', '--target-port', '8501',
        '--transport', 'http', '--cpu', '1.0', '--memory', '2Gi',
        '--min-replicas', '0', '--max-replicas', '1',
        '--env-vars') + $appVariables + $groupArgs) | Out-Null
} else {
    Invoke-Azure (@('containerapp', 'update', '--name', $AppName, '--image', $image,
        '--min-replicas', '0', '--max-replicas', '1',
        '--set-env-vars') + $appVariables + $groupArgs) | Out-Null
}

$registrations = @(Invoke-Azure @('ad', 'app', 'list', '--display-name', 'minecraft-generator-web'))
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
        preAuthorizedApplications = @(@{
            appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
            delegatedPermissionIds = @($scopeId)
        })
    }
}
$manifestFile = Join-Path ([System.IO.Path]::GetTempPath()) "minecraft-manifest-$PID.json"
try {
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestFile -Encoding utf8
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
            redirectToProvider = 'azureactivedirectory'
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled = $true
                registration = @{
                    clientId = $registration.appId
                    clientSecretSettingName = 'entra-client-secret'
                    openIdIssuer = "https://login.microsoftonline.com/$($account.tenantId)/v2.0"
                }
                validation = @{
                    allowedAudiences = @($registration.appId, "api://$($registration.appId)")
                    defaultAuthorizationPolicy = @{ allowedPrincipals = @{ identities = @($ownerId) } }
                }
            }
        }
        login = @{ tokenStore = @{ enabled = $false } }
        httpSettings = @{ requireHttps = $true }
    }
}
$authFile = Join-Path ([System.IO.Path]::GetTempPath()) "minecraft-auth-$PID.json"
try {
    $auth | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $authFile -Encoding utf8
    Invoke-Azure @('rest', '--method', 'PUT', '--url',
        "https://management.azure.com$resourcePrefix/Microsoft.App/containerApps/$AppName/authConfigs/current?api-version=2025-01-01",
        '--body', "@$authFile") | Out-Null
} finally {
    Remove-Item -LiteralPath $authFile -ErrorAction SilentlyContinue
}
Invoke-Azure (@('containerapp', 'ingress', 'enable', '--name', $AppName,
    '--type', 'external', '--target-port', '8501', '--transport', 'http') + $groupArgs) |
    Out-Null

[ordered]@{
    url = $url
    image = $image
    imageModel = $ImageModel
    visionModel = $VisionModel
    identityId = $managedIdentity.id
    loginAppId = $registration.appId
} | ConvertTo-Json
