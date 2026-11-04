# Minecraft Character Studio

A web application that turns a text description or photo into a Minecraft-style
character, with PNG downloads and expiring QR sharing links.

Based on [drhelius/oai-minecraft-generator](https://github.com/drhelius/oai-minecraft-generator).
The original MIT license and attribution are preserved in `LICENSE`.

## Run the application

Deploy the application to your own Azure subscription by following the
[deployment instructions](#azure-deployment). The deployment prints the URLs
for your generator, download gateway and (unless disabled) invitation portal.
No URL or account from a maintainer's Azure environment is required.

The hosted interface supports descriptions, webcam capture and uploaded photos.
Browser camera access requires permission and HTTPS. Only users authorized by
the deployment administrator can sign in.

### Photo analysis preview

In the photo tab, grant permission and capture or upload a photo. Each new photo
is analyzed automatically, and **Lo que ve la IA** shows its Spanish description
before you generate a character. This is snapshot analysis, not continuous video.
Generation reuses that description instead of sending the same photo twice.
Changing/removing the photo or withdrawing permission clears the previous
description. Use **Volver a analizar** to retry; photo analysis has a 30-second
per-session cooldown.

## Manage access for colleagues and friends

Open the invitation portal URL printed by the deployment, or use
**Invitar compañeros y amigos** in the generator. Only the deployment
administrator can open it. Enter an email and select **Dar acceso y enviar correo**.
The portal creates/reuses the Entra account, verifies both application access
controls, and sends a Spanish email containing the guest acceptance link when
needed, the application/sign-in links, and photo/generation/download instructions.
Existing directory users also receive the instructions email.
If the Azure sign-in session expires, the portal renews sign-in instead of trying
to parse an empty authentication response as JSON. If renewal fails, use
**Iniciar sesion de nuevo**. Gateway errors show their HTTP status; an unconfirmed
submission is never reported as an older invitation's success.
Use an address with a working mailbox: an Entra sign-in name does not necessarily
receive email. Delivery failures such as a nonexistent recipient domain are
recorded in the email delivery diagnostics, even after the send was accepted.

The **Usuarios y accesos** section lists authorized users with their name, email
and application access status. Search by name/email, refresh the list, or select
**Revocar acceso** and confirm. Revocation removes access from both controls
without deleting the Entra account or affecting other applications, and sends no
email. The administrator is protected in the interface, API and worker. Use the
invitation form to restore access and resend instructions.
Deleted directory accounts and mismatched access controls remain visible rather
than being silently hidden; directory/permission errors are shown explicitly.

An Azure Container Apps Job performs each access operation independently of the browser.
The portal shows progress and the ten most recent executions. Only one access
operation can run at a time; retries of the same request reuse its execution.
A successful invitation means Azure Communication Services accepted the email for delivery,
not that the recipient has opened it or that their mailbox has accepted it.
Check spam/junk if necessary. A failed operation is not reported as success:
permissions may have been partially updated, so inspect the job logs before retrying.

### Command-line administration and revocation

Run these commands from the repository in PowerShell, signed into Azure CLI as
the administrator who deployed this instance. Set `$subscription` and
`$resourceGroup` to the values used for deployment:

```powershell
.\infra\access.ps1 -Action List -Subscription $subscription -ResourceGroup $resourceGroup
.\infra\access.ps1 -Action Add -Email friend@example.com -Subscription $subscription -ResourceGroup $resourceGroup
.\infra\access.ps1 -Action Remove -Email friend@example.com -Subscription $subscription -ResourceGroup $resourceGroup
```

`Add` reuses an existing directory account or sends a Microsoft Entra B2B guest
invitation when needed. The friend accepts that email and signs into the same
application with their own account. The automation updates and verifies both
Entra authorization and `ALLOWED_USER_IDS`; no Azure subscription or GitHub role
is granted. Repeating `Add` does not reinvite an existing matching user.

Preview an operation without inviting anyone or changing access:

```powershell
.\infra\access.ps1 -Action Add -Email friend@example.com -Subscription $subscription -ResourceGroup $resourceGroup -WhatIf
```

`Remove` revokes application access without deleting the directory account, and
cannot remove the administrator. It also accepts `-UserId <object-id>` from
`List`, including IDs whose directory account was already deleted. Existing
in-flight generations might finish while the runtime revision is replaced.

The Entra principal allowlist is the durable source of access configuration:
redeployments preserve it instead of resetting everyone to the administrator.
If updating the runtime fails after updating Entra, the error is explicit;
repeat the same command to synchronize both controls. Run only one deployment
or access-changing command at a time. Permissions can take a short time to
propagate, and changing the allowlist can restart browser sessions.

## Azure deployment

The deployment script creates the resource group, Azure OpenAI account, private
StorageV2 account, Container Apps environment, registry, managed identities,
Log Analytics workspace and private networking in the subscription you select.
It deploys the configured models to the new or existing Azure OpenAI account.
The storage account is configured to deny public and anonymous access. Existing
resources with the names you provide are reused; do not point it at storage used
by another workload because the deployment disables its public network access.

- Invitations: a separate administrator-only Container App, a manual Container
  Apps Job, Azure Communication Services Email, and an Azure-managed sending
  domain with engagement tracking disabled. The portal scales to zero and the
  worker runs only when requested. Email data location is Europe.
  Email send and delivery-status diagnostics go to the deployment's Log Analytics
  workspace; engagement/open tracking remains disabled.
- Image generation: `gpt-image-2.5-sunburst` (`2026-09-08`).
- Photo analysis: `gpt-6.1-sol` (`2026-09-29`) via the Responses API.
- Sign-in: single-tenant Microsoft Entra ID, restricted to the administrator and
  users authorized by the access automation.
- Service authentication: managed identity and resource-scoped RBAC. No model
  API keys or storage connection strings are used.
- Sharing: private blobs with HTTPS-only, read-only user-delegation SAS links
  that expire after one hour, served through a small download gateway. Storage
  validates the signature through its private endpoint. The gateway has no model
  or storage RBAC role and never substitutes its own credentials.
- Photos: resized, stripped of metadata and sent to the vision model with
  `store=False`; the application does not persist the original photo.

Install Azure CLI with the Container Apps extension, sign in to the tenant that
owns your subscription, and ensure the selected subscription has quota and access
to the configured model versions. The script creates the resource group and
resources on the first run, then reuses them on later runs. Use a fresh suffix
for globally unique Azure resource names; if Azure reports a name is taken,
choose another suffix and rerun with the same values:

```powershell
az login
$subscription = "<your-subscription-id>"
$suffix = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$deployment = @{
    Subscription = $subscription
    ResourceGroup = "rg-minecraft-generator"
    Location = "swedencentral"
    FoundryAccount = "mcgen-foundry-$suffix"
    StorageAccount = "mcgen$suffix"
    Registry = "mcgenacr$suffix"
    CommunicationName = "mcgencomm$suffix"
    EmailName = "mcgenemail$suffix"
}
$resourceGroup = $deployment.ResourceGroup
.\infra\deploy.ps1 @deployment
```

The script uses the signed-in Azure CLI user by default, verifies the Microsoft
Graph identity matches, and selects the required subscription. Use
`-DeploymentAccount <user-principal-name>` to require a specific user. Runtime
service access uses managed identities, not the administrator's credentials.
The deploying user needs permission to create resources, assign Azure roles and
register Entra applications; the invitation portal also needs Entra administrator
consent for its documented Microsoft Graph application permissions.

The script prints the application URL and model deployment names, not secrets.
The cloud image build runs lint, formatting checks and all unit/UI tests on
Python 3.12 before producing the runtime image. A failing check prevents release.
It can also run the `Foundation` and `Release` phases separately:

```powershell
.\infra\deploy.ps1 @deployment -Phase Foundation
.\infra\deploy.ps1 @deployment -Phase Release
```

To resume configuration after a failed release without rebuilding an already
verified image, supply its tag with `-ImageTag <tag> -SkipBuild`.

The image/vision model names and versions are parameters on `deploy.ps1`.
Defaults match the versions used by the maintained deployment, but availability,
model access, quota and regional capacity vary by subscription. Override
`-ImageModel`, `-ImageVersion`, `-VisionModel` and `-VisionVersion` with
deployments available to your subscription when needed. A failing model
deployment must be resolved before release.

Storage public network access and anonymous blob access remain **disabled**.
Both applications reach it through the VNet/private endpoint. Signed QR links
open the HTTPS download gateway from phones, without exposing Storage to the
internet or bypassing the subscription's network policy. The gateway disables
query-string access logs so SAS signatures are not logged.

The Entra login client secret is stored only as a Container Apps secret and
expires one year after initial deployment. The web and administration portal have
separate login secrets. Rotate each in Entra and update its `entra-client-secret`
Container Apps secret before expiry.

`infra\portal.ps1` provisions the email resources/identities in `Foundation` and
deploys the portal/job in `Release`; `deploy.ps1` invokes both automatically.
Use `-SkipPortal` only for a generator-only release after the portal is installed.
Initial provisioning also requires Entra administrator consent for the worker's
`User.ReadBasic.All` and `User.Invite.All` application permissions, and the portal's
`User.ReadBasic.All` permission to display basic directory profiles. The worker's custom Azure
roles are scoped to the generator and communication resource. The portal has
read-only generator/auth-configuration access and can read/start its access job,
but cannot edit the generator directly or delete directory accounts. Job start
permission permits overriding the job template and using its identity, so the
portal remains a trusted administrative component, not an isolation boundary.
It validates administrator identity, same-origin requests, CSRF, email and request
fields; it never accepts arbitrary job commands or templates from the browser.

## Testing

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\ruff.exe check .
.\.venv\Scripts\ruff.exe format --check .
.\.venv\Scripts\python.exe -m pytest -q
node --test .\tests\test_portal_client.cjs
.\tests\test_deploy.ps1
.\tests\test_access.ps1
```

The PowerShell tests mock Azure CLI and check deployment identity, guest
invitations, both authorization controls, revocation, failure recovery and
preservation of access during redeployment. They do not send real invitations.
The Node.js client regression tests cover empty authentication/gateway responses,
safe sign-in recovery, unconfirmed submissions, user search, protected administrator
controls and revocation confirmation. The image build runs them in
a separate Node.js 24 stage; Node.js is not included in the runtime image.
Python tests also cover administrator-only invitation access, CSRF, invalid input,
new/existing users, durable job submission, idempotency, email failure handling,
user listing, partial revocation recovery and the worker's no-email revocation path.

`scripts\smoke_test.py` performs real image generation, private blob upload,
signed/unsigned download checks, vision analysis, and a second generation from
the analyzed image. It incurs inference charges and should run with the app's
managed identity and environment variables, for example in a temporary Container
Apps job using the same image and identity. It logs pass/fail results, not images,
signed URLs, prompts or photo descriptions.

## Local development (optional)

Azure hosts the application; users do not need Python or local software.
For development only, copy `.env.sample` to `.env`, set the deployment names and
endpoints, sign in with `az login`, and run:

```powershell
.\.venv\Scripts\streamlit.exe run app.py
```

The local developer identity needs `Cognitive Services OpenAI User` on the model
resource and `Storage Blob Data Contributor` on the storage account.
`REQUIRE_AUTH=false` is for local development only. Production requires both
Container Apps authentication and an `ALLOWED_USER_IDS` allowlist.

## Costs and limitations

All web containers scale to zero when idle; registry storage, private endpoints,
private DNS, networking and Log Analytics can still incur charges. Models are
consumption-billed per request. High-quality
image generation can take one or two minutes. Only one generation runs at a time,
and per-session cooldown plus the deployed model quota limit request volume.
The app's in-memory result disappears if the session/container restarts; download
the PNG or use its sharing link before expiry. Generated blobs remain private in
the storage account you selected until deleted by its administrator.

Invitations incur job execution and email delivery charges. The Azure-managed
email domain is intended for testing/low volume and has service sending quotas;
use a verified custom domain and request quota increases before bulk use. The
portal is not a mailing-list or bulk-invitation service. Never run CLI access
changes or redeploy the generator concurrently with an access job.

## Repository layout

The original single-file Streamlit application remains at the repository root.
The generation, storage, model configuration and photo-analysis modules are
separate root-level Python files. `portal/` contains the invitation UI,
`infra/` contains Azure provisioning and access scripts, `scripts/` contains
operational checks, and `tests/` covers the application and deployment tooling.
