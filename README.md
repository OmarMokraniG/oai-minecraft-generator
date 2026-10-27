# Minecraft Character Studio

A web application that turns a text description or photo into a Minecraft-style
character, with PNG downloads and expiring QR sharing links.

Based on [drhelius/oai-minecraft-generator](https://github.com/drhelius/oai-minecraft-generator).
The original MIT license and attribution are preserved in `LICENSE`.

## Open the application

[Minecraft Character Studio](https://ca-minecraftgen-web.jollyocean-203dead9.swedencentral.azurecontainerapps.io/)

Sign in with the Microsoft account authorized for this deployment. The interface
supports descriptions, webcam capture and uploaded photos. No local installation
is needed. Browser camera access requires permission and HTTPS.

If your browser has another Microsoft account signed in, use
[Choose the deployment account](https://ca-minecraftgen-web.jollyocean-203dead9.swedencentral.azurecontainerapps.io/.auth/login/aad?post_login_redirect_uri=%2F).
The sign-in flow explicitly offers account selection; only authorized users can
proceed.

### Photo analysis preview

In the photo tab, grant permission and capture or upload a photo. Each new photo
is analyzed automatically, and **Lo que ve la IA** shows its Spanish description
before you generate a character. This is snapshot analysis, not continuous video.
Generation reuses that description instead of sending the same photo twice.
Changing/removing the photo or withdrawing permission clears the previous
description. Use **Volver a analizar** to retry; photo analysis has a 30-second
per-session cooldown.

## Manage access for colleagues and friends

[Open the invitation portal](https://ca-minecraftgen-admin.jollyocean-203dead9.swedencentral.azurecontainerapps.io/),
or use **Invitar compañeros y amigos** in the generator. Only the deployment
administrator can open it. Enter an email and select **Dar acceso y enviar correo**.
The portal creates/reuses the Entra account, verifies both application access
controls, and sends a Spanish email containing the guest acceptance link when
needed, the application/sign-in links, and photo/generation/download instructions.
Existing directory users also receive the instructions email.
Use an address with a working mailbox: an Entra sign-in name does not necessarily
receive email. Delivery failures such as a nonexistent recipient domain are
recorded in the email delivery diagnostics, even after the send was accepted.

An Azure Container Apps Job performs each invitation independently of the browser.
The portal shows progress and the ten most recent executions. Only one invitation
can run at a time; retries of the same request reuse its execution. A successful
execution means Azure Communication Services accepted the email for delivery,
not that the recipient has opened it or that their mailbox has accepted it.
Check spam/junk if necessary. A failed operation is not reported as success:
access may already exist, so inspect the job logs before retrying.

### Command-line administration and revocation

Run these commands from the repository in PowerShell, signed into Azure CLI as
the configured deployment administrator:

```powershell
.\infra\access.ps1 -Action List
.\infra\access.ps1 -Action Add -Email friend@example.com
.\infra\access.ps1 -Action Remove -Email friend@example.com
```

`Add` reuses an existing directory account or sends a Microsoft Entra B2B guest
invitation when needed. The friend accepts that email and signs into the same
application with their own account. The automation updates and verifies both
Entra authorization and `ALLOWED_USER_IDS`; no Azure subscription or GitHub role
is granted. Repeating `Add` does not reinvite an existing matching user.

Preview an operation without inviting anyone or changing access:

```powershell
.\infra\access.ps1 -Action Add -Email friend@example.com -WhatIf
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

The deployment uses the existing resource group `rg-minecraftgenerator-001` in
Sweden Central. It adds Consumption Azure Container Apps for the web interface
and signed downloads (each 0-1 replicas), a Basic Azure Container Registry,
managed identities, a Log Analytics workspace, and a VNet with a Storage private
endpoint and private DNS.
The existing Foundry account and storage account are reused without deleting
their other resources or deployments.

- Invitations: a separate administrator-only Container App, a manual Container
  Apps Job, Azure Communication Services Email, and an Azure-managed sending
  domain with engagement tracking disabled. The portal scales to zero and the
  worker runs only when requested. Email data location is Europe.
    Email send and delivery-status diagnostics go to the existing Log Analytics
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

Install Azure CLI with the Container Apps extension, sign into the intended
tenant/subscription, and run in PowerShell:

```powershell
.\infra\deploy.ps1
```

The script's `DeploymentAccount` parameter defaults to this deployment's Azure
administrator. It verifies both the Azure CLI and Microsoft Graph user before
provisioning, selects the target subscription, and refuses to deploy under a
different account. Runtime service access still uses managed identities, not the
administrator's credentials.

The script prints the application URL and model deployment names, not secrets.
The cloud image build runs lint, formatting checks and all unit/UI tests on
Python 3.12 before producing the runtime image. A failing check prevents release.
It can also run the `Foundation` and `Release` phases separately:

```powershell
.\infra\deploy.ps1 -Phase Foundation
.\infra\deploy.ps1 -Phase Release
```

To resume configuration after a failed release without rebuilding an already
verified image, supply its tag with `-ImageTag <tag> -SkipBuild`.

Deployment requires permission to create resources and role assignments in the
resource group, deploy the selected models, and register an Entra application.
The model/version parameters must match the live catalog and available quota.
Regional model capacity and availability are checked during provisioning.

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
`User.ReadBasic.All` and `User.Invite.All` application permissions. Its custom Azure
roles are scoped to the generator and communication resource. The portal can
read/start only its invitation job, not edit the generator directly. Job start
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
.\tests\test_deploy.ps1
.\tests\test_access.ps1
```

The PowerShell tests mock Azure CLI and check deployment identity, guest
invitations, both authorization controls, revocation, failure recovery and
preservation of access during redeployment. They do not send real invitations.
Python tests also cover administrator-only invitation access, CSRF, invalid input,
new/existing users, durable job submission, idempotency, and email failure handling.

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
the existing storage account until deleted by its administrator.

Invitations incur job execution and email delivery charges. The Azure-managed
email domain is intended for testing/low volume and has service sending quotas;
use a verified custom domain and request quota increases before bulk use. The
portal is not a mailing-list or bulk-invitation service. Never run CLI access
changes or redeploy the generator concurrently with an invitation job.
