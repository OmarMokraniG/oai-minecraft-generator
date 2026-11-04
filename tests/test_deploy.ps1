$ErrorActionPreference = 'Stop'
$deploymentAccount = 'test-admin@example.invalid'
$deployment = @{
    Subscription = 'test-subscription'
    ResourceGroup = 'test-resource-group'
    FoundryAccount = 'test-foundry'
    StorageAccount = 'teststorage'
    Registry = 'testregistry'
    CommunicationName = 'test-communication'
    EmailName = 'test-email'
}
$state = @{ Calls = [System.Collections.Generic.List[string]]::new() }

function New-TestToken {
    param([string]$ObjectId)
    $claims = @{ oid = $ObjectId; tid = 'test-tenant' } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($claims))
    "header.$($payload.TrimEnd('=').Replace('+', '-').Replace('/', '_')).signature"
}

function az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $command = $Arguments[0..1] -join ' '
    $state.Calls.Add($command)
    switch ($command) {
        'account show' {
            return @{
                user = @{ name = $state.CliUser; type = $state.CliType }
                tenantId = 'test-tenant'
            } | ConvertTo-Json
        }
        'account set' { return }
        'account get-access-token' {
            return @{ accessToken = New-TestToken 'test-user-id' } | ConvertTo-Json
        }
        'ad signed-in-user' {
            return @{
                id = $state.GraphId
                userPrincipalName = $state.GraphUser
            } | ConvertTo-Json
        }
        'identity show' { throw 'Identity validation passed; stop before provisioning.' }
        default { throw "Unexpected Azure operation: $command" }
    }
}

$cases = @(
    @{
        Name = 'Rejects another Azure CLI user'
        CliUser = 'other@example.invalid'; CliType = 'user'
        GraphUser = $deploymentAccount
        Expected = 'The signed-in Azure CLI user does not match'; Calls = 1
    },
    @{
        Name = 'Rejects a service principal as the deployment account'
        CliUser = $deploymentAccount; CliType = 'servicePrincipal'
        GraphUser = $deploymentAccount
        Expected = 'Sign in to Azure CLI as a Microsoft Entra user'; Calls = 1
    },
    @{
        Name = 'Rejects a mismatched Microsoft Graph session'
        CliUser = $deploymentAccount; CliType = 'user'
        GraphUser = $deploymentAccount; GraphId = 'other-user-id'
        Expected = 'The Microsoft Graph session does not match'; Calls = 4
    },
    @{
        Name = 'Accepts the signed-in user without a hard-coded account'
        CliUser = 'current@example.invalid'; CliType = 'user'
        GraphUser = 'current@example.invalid'
        Expected = 'Identity validation passed; stop before provisioning.'; Calls = 5
        UseAccountOverride = $false
    },
    @{
        Name = 'Accepts the configured user case-insensitively'
        CliUser = $deploymentAccount.ToUpperInvariant(); CliType = 'user'
        GraphUser = $deploymentAccount.ToUpperInvariant()
        Expected = 'Identity validation passed; stop before provisioning.'; Calls = 5
    }
)

foreach ($case in $cases) {
    $state.Calls.Clear()
    $state.CliUser = $case.CliUser
    $state.CliType = $case.CliType
    $state.GraphUser = $case.GraphUser
    $state.GraphId = if ($case.GraphId) { $case.GraphId } else { 'test-user-id' }
    $parameters = @{} + $deployment
    $parameters.Phase = 'Release'
    $parameters.SkipBuild = $true
    if ($case.UseAccountOverride -ne $false) {
        $parameters.DeploymentAccount = $deploymentAccount
    }
    try {
        & "$PSScriptRoot\..\infra\deploy.ps1" @parameters
        throw 'Deployment unexpectedly completed.'
    } catch {
        if (-not $_.Exception.Message.StartsWith($case.Expected)) {
            throw
        }
    }
    if ($state.Calls.Count -ne $case.Calls) {
        throw "Unexpected Azure operations for test: $($case.Name)"
    }
    Write-Output "PASS $($case.Name)"
}
