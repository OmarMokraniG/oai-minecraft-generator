[CmdletBinding()]
param(
    [ValidateSet('Foundation', 'Release')][string]$Phase,
    [Parameter(Mandatory)][string]$Subscription,
    [string]$DeploymentAccount,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = 'swedencentral',
    [Parameter(Mandatory)][string]$Registry,
    [Parameter(Mandatory)][string]$Environment,
    [string]$AppName = 'ca-minecraftgen-web',
    [Parameter(Mandatory)][string]$StorageAccount,
    [Parameter(Mandatory)][string]$CommunicationName,
    [Parameter(Mandatory)][string]$EmailName,
    [string]$ImageTag
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
. "$PSScriptRoot\azure.ps1"
$session = Assert-DeploymentAccount -Subscription $Subscription -DeploymentAccount $DeploymentAccount
$ownerId = $session.User.id
$DeploymentAccount = $session.DeploymentAccount
$groupArgs = @('--resource-group', $ResourceGroup, '--subscription', $Subscription)
$groupId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup"
$prefix = "$groupId/providers"
$portalName = 'ca-minecraftgen-admin'
$jobName = 'job-minecraftgen-invite'
$communicationName = $CommunicationName
$emailName = $EmailName
$communicationId = "$prefix/Microsoft.Communication/communicationServices/$communicationName"
$emailId = "$prefix/Microsoft.Communication/emailServices/$emailName"
$domainId = "$emailId/domains/AzureManagedDomain"
$jobId = "$prefix/Microsoft.App/jobs/$jobName"
$webId = "$prefix/Microsoft.App/containerApps/$AppName"
$storageId = "$prefix/Microsoft.Storage/storageAccounts/$StorageAccount"
$lockId = Get-AccessLockId -StorageId $storageId
$roleSuffix = "$Subscription $ResourceGroup".ToLowerInvariant()

function Ensure-CustomRole {
    param([string]$Name, [string[]]$Actions)
    $existing = @(Invoke-Azure @('role', 'definition', 'list', '--name', $Name, '--scope', $groupId,
        '--subscription', $Subscription))
    if ($existing.Count -gt 1) { throw "Multiple definitions for role $Name" }
    $roleId = if ($existing.Count) { $existing[0].name } else { [guid]::NewGuid() }
    $id = "/subscriptions/$Subscription/providers/Microsoft.Authorization/roleDefinitions/$roleId"
    Invoke-AzureJson -Method PUT -Url "https://management.azure.com${id}?api-version=2022-04-01" -Body @{
        properties = @{
            roleName = $Name; type = 'CustomRole'
            description = 'Resource-scoped permissions for Minecraft invitations.'
            assignableScopes = @($groupId)
            permissions = @(@{ actions = $Actions; notActions = @(); dataActions = @(); notDataActions = @() })
        }
    } | Out-Null
}

function Wait-Resource {
    param([string]$Id)
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $resource = Invoke-Azure @('rest', '--method', 'GET', '--url',
            "https://management.azure.com${Id}?api-version=2023-03-31")
        if ($resource.properties.provisioningState -eq 'Succeeded') { return $resource }
        if ($resource.properties.provisioningState -in @('Failed', 'Canceled')) {
            throw "Provisioning failed for $Id"
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "Provisioning is still pending for $Id"
}

if ($Phase -eq 'Foundation') {
    $provider = Invoke-Azure @('provider', 'show', '--namespace', 'Microsoft.Communication',
        '--subscription', $Subscription)
    if ($provider.registrationState -ne 'Registered') {
        Invoke-Azure @('provider', 'register', '--namespace', 'Microsoft.Communication',
            '--subscription', $Subscription, '--wait') | Out-Null
    }
    Invoke-AzureJson -Method PUT -Url "https://management.azure.com${emailId}?api-version=2023-03-31" -Body @{
        location = 'global'; properties = @{ dataLocation = 'Europe' }
    } | Out-Null
    Wait-Resource $emailId | Out-Null
    Invoke-AzureJson -Method PUT -Url "https://management.azure.com${domainId}?api-version=2023-03-31" -Body @{
        location = 'global'
        properties = @{ domainManagement = 'AzureManaged'; userEngagementTracking = 'Disabled' }
    } | Out-Null
    Wait-Resource $domainId | Out-Null
    Invoke-AzureJson -Method PUT -Url "https://management.azure.com${communicationId}?api-version=2023-03-31" -Body @{
        location = 'global'
        properties = @{ dataLocation = 'Europe'; linkedDomains = @($domainId) }
    } | Out-Null
    Wait-Resource $communicationId | Out-Null
    Invoke-AzureJson -Method PUT -Url (
        "https://management.azure.com$communicationId/providers/microsoft.insights/diagnosticSettings/email-delivery?api-version=2021-05-01-preview"
    ) -Body @{
        properties = @{
            workspaceId = "$prefix/Microsoft.OperationalInsights/workspaces/law-minecraftgen-001"
            logAnalyticsDestinationType = 'Dedicated'
            logs = @(
                @{ category = 'EmailSendMailOperational'; enabled = $true },
                @{ category = 'EmailStatusUpdateOperational'; enabled = $true }
            )
        }
    } | Out-Null
    foreach ($name in @('id-minecraftgen-admin', 'id-minecraftgen-invite')) {
        $identities = @(Invoke-Azure (@('identity', 'list') + $groupArgs))
        if ($name -notin $identities.name) {
            Invoke-Azure (@('identity', 'create', '--name', $name, '--location', $Location) + $groupArgs) |
                Out-Null
        }
        $identity = Invoke-Azure (@('identity', 'show', '--name', $name) + $groupArgs)
        Grant-Role "$prefix/Microsoft.ContainerRegistry/registries/$Registry" $identity.principalId 'AcrPull'
    }
    Ensure-CustomRole "Minecraft Invitation Access Writer $roleSuffix" @(
        'Microsoft.App/containerApps/read', 'Microsoft.App/containerApps/write',
        'Microsoft.App/containerApps/authConfigs/read', 'Microsoft.App/containerApps/authConfigs/write'
    )
    Ensure-CustomRole "Minecraft Access Reader $roleSuffix" @(
        'Microsoft.App/containerApps/read', 'Microsoft.App/containerApps/authConfigs/read'
    )
    Ensure-CustomRole "Minecraft Invitation Job Starter $roleSuffix" @(
        'Microsoft.App/jobs/read', 'Microsoft.App/jobs/start/action', 'Microsoft.App/jobs/executions/read'
    )
    Ensure-CustomRole "Minecraft Access Lock User $roleSuffix" @(
        'Microsoft.Storage/storageAccounts/blobServices/containers/lease/action'
    )
    Ensure-CustomRole "Minecraft Invitation Email Sender $roleSuffix" @(
        'Microsoft.Communication/communicationServices/read',
        'Microsoft.Communication/communicationServices/write',
        'Microsoft.Communication/emailServices/write'
    )
    $worker = Invoke-Azure (@('identity', 'show', '--name', 'id-minecraftgen-invite') + $groupArgs)
    Grant-Role $communicationId $worker.principalId "Minecraft Invitation Email Sender $roleSuffix"
    $graph = Invoke-Azure @('ad', 'sp', 'show', '--id', '00000003-0000-0000-c000-000000000000')
    $reader = Invoke-Azure (@('identity', 'show', '--name', 'id-minecraftgen-admin') + $groupArgs)
    foreach ($target in @(
        @{ identity = $worker; permissions = @('User.ReadBasic.All', 'User.Invite.All') },
        @{ identity = $reader; permissions = @('User.ReadBasic.All') }
    )) {
        $principal = $target.identity.principalId
        $assignmentsUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$principal/appRoleAssignments"
        foreach ($permission in $target.permissions) {
            $role = @($graph.appRoles | Where-Object {
                $_.value -eq $permission -and 'Application' -in $_.allowedMemberTypes
            })
            if ($role.Count -ne 1) { throw "Cannot resolve Graph application role $permission" }
            $assigned = Invoke-Azure @('rest', '--method', 'GET', '--url', $assignmentsUrl)
            if ($role[0].id -notin $assigned.value.appRoleId) {
                Invoke-AzureJson -Method POST -Url $assignmentsUrl -Body @{
                    principalId = $principal; resourceId = $graph.id; appRoleId = $role[0].id
                } | Out-Null
            }
        }
    }
    Write-Output 'Invitation email and managed identities provisioned.'
    return
}

if (-not $ImageTag) { throw 'Release requires an existing verified ImageTag.' }
$portalIdentity = Invoke-Azure (@('identity', 'show', '--name', 'id-minecraftgen-admin') + $groupArgs)
$worker = Invoke-Azure (@('identity', 'show', '--name', 'id-minecraftgen-invite') + $groupArgs)
$environmentResource = Invoke-Azure (@('containerapp', 'env', 'show', '--name', $Environment) + $groupArgs)
$domain = Wait-Resource $domainId
$communication = Wait-Resource $communicationId
if (-not $domain.properties.fromSenderDomain -or -not $communication.properties.hostName) {
    throw 'The verified email domain or communication endpoint is missing.'
}
$sender = "DoNotReply@$($domain.properties.fromSenderDomain)"
$endpoint = "https://$($communication.properties.hostName)"
$generatorUrl = "https://$AppName.$($environmentResource.properties.defaultDomain)"
$portalUrl = "https://$portalName.$($environmentResource.properties.defaultDomain)"
$image = "$Registry.azurecr.io/minecraft-generator:$ImageTag"
Grant-Role $webId $worker.principalId "Minecraft Invitation Access Writer $roleSuffix"
Grant-Role $webId $portalIdentity.principalId "Minecraft Access Reader $roleSuffix"
Grant-Role $lockId $worker.principalId "Minecraft Access Lock User $roleSuffix"
Invoke-AzureJson -Method PUT -Url "https://management.azure.com${jobId}?api-version=2025-01-01" -Body @{
    location = $Location
    identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $worker.id = @{} } }
    properties = @{
        environmentId = $environmentResource.id
        configuration = @{
            triggerType = 'Manual'; replicaTimeout = 900; replicaRetryLimit = 0
            manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 }
            registries = @(@{ server = "$Registry.azurecr.io"; identity = $worker.id })
        }
        template = @{ containers = @(@{
            name = 'invitation-worker'; image = $image; command = @('python', 'invitation_worker.py')
            resources = @{ cpu = 0.5; memory = '1Gi' }
            env = @(
                @{ name = 'AZURE_CLIENT_ID'; value = $worker.clientId },
                @{ name = 'ADMIN_USER_ID'; value = $ownerId },
                @{ name = 'GENERATOR_RESOURCE_ID'; value = $webId },
                @{ name = 'ACCESS_LOCK_ID'; value = $lockId },
                @{ name = 'GENERATOR_URL'; value = $generatorUrl },
                @{ name = 'EMAIL_ENDPOINT'; value = $endpoint },
                @{ name = 'EMAIL_SENDER'; value = $sender }
            )
        }) }
    }
} | Out-Null
Grant-Role $jobId $portalIdentity.principalId "Minecraft Invitation Job Starter $roleSuffix"
$variables = @(
    "AZURE_CLIENT_ID=$($portalIdentity.clientId)", "ADMIN_USER_ID=$ownerId",
    "PORTAL_BASE_URL=$portalUrl", "GENERATOR_URL=$generatorUrl",
    "INVITATION_JOB_RESOURCE_ID=$jobId", "GENERATOR_RESOURCE_ID=$webId",
    'APP_HEALTH_URL=http://127.0.0.1:8000/health'
)
$apps = @(Invoke-Azure (@('containerapp', 'list') + $groupArgs))
if ($portalName -notin $apps.name) {
    Invoke-Azure (@('containerapp', 'create', '--name', $portalName,
        '--environment', $environmentResource.id, '--image', $image,
        '--registry-server', "$Registry.azurecr.io", '--registry-identity', $portalIdentity.id,
        '--user-assigned', $portalIdentity.id, '--ingress', 'internal', '--target-port', '8000',
        '--transport', 'http', '--cpu', '0.25', '--memory', '0.5Gi',
        '--min-replicas', '0', '--max-replicas', '1',
        '--command', 'python', '--args', 'portal_app.py', '--env-vars') + $variables + $groupArgs) | Out-Null
} else {
    Invoke-Azure (@('containerapp', 'update', '--name', $portalName, '--image', $image,
        '--set-env-vars') + $variables + $groupArgs) | Out-Null
}
$registrations = @(Invoke-Azure @('ad', 'app', 'list', '--display-name', 'minecraft-generator-web'))
if ($registrations.Count -ne 1) { throw 'Exactly one generator Entra application is required.' }
$registration = $registrations[0]
$redirects = @($registration.web.redirectUris) + @("$portalUrl/.auth/login/aad/callback")
Invoke-Azure (@('ad', 'app', 'update', '--id', $registration.id, '--web-redirect-uris') +
    @($redirects | Sort-Object -Unique)) | Out-Null
$portal = Invoke-Azure (@('containerapp', 'show', '--name', $portalName) + $groupArgs)
if ('entra-client-secret' -notin $portal.properties.configuration.secrets.name) {
    $credential = Invoke-Azure @('ad', 'app', 'credential', 'reset', '--id', $registration.id,
        '--append', '--display-name', 'Access portal login', '--years', '1')
    Invoke-Azure (@('containerapp', 'secret', 'set', '--name', $portalName, '--secrets',
        "entra-client-secret=$($credential.password)") + $groupArgs) | Out-Null
    $credential = $null
}
$auth = @{
    properties = @{
        platform = @{ enabled = $true }
        globalValidation = @{ unauthenticatedClientAction = 'RedirectToLoginPage'; redirectToProvider = 'aad' }
        httpSettings = @{ requireHttps = $true }
        login = @{ tokenStore = @{ enabled = $false } }
        identityProviders = @{ azureActiveDirectory = @{
            enabled = $true
            login = @{ loginParameters = @('prompt=select_account', "login_hint=$DeploymentAccount") }
            registration = @{
                clientId = $registration.appId; clientSecretSettingName = 'entra-client-secret'
                openIdIssuer = "https://login.microsoftonline.com/$($session.Account.tenantId)/v2.0"
            }
            validation = @{
                allowedAudiences = @($registration.appId, "api://$($registration.appId)")
                defaultAuthorizationPolicy = @{
                    allowedApplications = @($registration.appId, '04b07795-8ddb-461a-bbee-02f9e1bf7b46')
                    allowedPrincipals = @{ identities = @($ownerId) }
                }
            }
        } }
    }
}
Invoke-AzureJson -Method PUT -Body $auth -Url (
    "https://management.azure.com$prefix/Microsoft.App/containerApps/$portalName/authConfigs/current?api-version=2025-01-01"
) | Out-Null
Invoke-Azure (@('containerapp', 'ingress', 'enable', '--name', $portalName,
    '--type', 'external', '--target-port', '8000', '--transport', 'http') + $groupArgs) | Out-Null
Write-Output "Invitation portal: $portalUrl"
