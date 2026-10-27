$ErrorActionPreference = 'Stop'
$deploymentAccount = 'test-admin@example.invalid'
$state = @{ Calls = [System.Collections.Generic.List[string]]::new() }

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
        'ad signed-in-user' {
            return @{
                id = 'test-user-id'
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
        Expected = 'Sign in to Azure CLI as '; Calls = 1
    },
    @{
        Name = 'Rejects a service principal as the deployment account'
        CliUser = $deploymentAccount; CliType = 'servicePrincipal'
        GraphUser = $deploymentAccount
        Expected = 'Sign in to Azure CLI as '; Calls = 1
    },
    @{
        Name = 'Rejects a mismatched Microsoft Graph session'
        CliUser = $deploymentAccount; CliType = 'user'
        GraphUser = 'other@example.invalid'
        Expected = 'The Microsoft Graph session does not match'; Calls = 3
    },
    @{
        Name = 'Accepts the configured user case-insensitively'
        CliUser = $deploymentAccount.ToUpperInvariant(); CliType = 'user'
        GraphUser = $deploymentAccount.ToUpperInvariant()
        Expected = 'Identity validation passed; stop before provisioning.'; Calls = 4
    }
)

foreach ($case in $cases) {
    $state.Calls.Clear()
    $state.CliUser = $case.CliUser
    $state.CliType = $case.CliType
    $state.GraphUser = $case.GraphUser
    try {
        & "$PSScriptRoot\..\infra\deploy.ps1" -Phase Release -SkipBuild `
            -DeploymentAccount $deploymentAccount
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
