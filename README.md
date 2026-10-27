# Minecraft Character Studio

A web application that turns a text description or photo into a Minecraft-style
character, with PNG downloads and expiring QR sharing links.

Based on [drhelius/oai-minecraft-generator](https://github.com/drhelius/oai-minecraft-generator).
The original MIT license and attribution are preserved in `LICENSE`.

## Open the application

[Minecraft Character Studio](https://ca-minecraftgen-001.livelydune-c908fb62.swedencentral.azurecontainerapps.io/)

Sign in with the Microsoft account authorized for this deployment. The interface
supports descriptions, webcam capture and uploaded photos. No local installation
is needed. Browser camera access requires permission and HTTPS.

## Azure deployment

The deployment uses the existing resource group `rg-minecraftgenerator-001` in
Sweden Central. It adds a Consumption Azure Container App (0-1 replicas), a Basic
Azure Container Registry, a managed identity and a Log Analytics workspace.
The existing Foundry account and storage account are reused without deleting
their other resources or deployments.

- Image generation: `gpt-image-2.5-sunburst` (`2026-09-08`).
- Photo analysis: `gpt-6.1-sol` (`2026-09-29`) via the Responses API.
- Sign-in: single-tenant Microsoft Entra ID, restricted to the deploying user.
- Service authentication: managed identity and resource-scoped RBAC. No model
  API keys or storage connection strings are used.
- Sharing: private blobs with HTTPS-only, read-only user-delegation SAS links
  that expire after one hour. Anonymous container access remains disabled.
- Photos: resized, stripped of metadata and sent to the vision model with
  `store=False`; the application does not persist the original photo.

Install Azure CLI with the Container Apps extension, sign into the intended
tenant/subscription, and run in PowerShell:

```powershell
.\infra\deploy.ps1
```

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

The storage public **network endpoint** is enabled so that signed QR links can
be opened from phones. This does not enable public blobs: image access still
requires a valid signature. Original photos are never uploaded.

The Entra login client secret is stored only as a Container Apps secret and
expires one year after initial deployment. Rotate it in Entra and update the
`entra-client-secret` Container Apps secret before expiry.

## Testing

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\ruff.exe check .
.\.venv\Scripts\ruff.exe format --check .
.\.venv\Scripts\python.exe -m pytest -q
```

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

The container scales to zero when idle; registry storage and Log Analytics can
still incur charges. Models are consumption-billed per request. High-quality
image generation can take one or two minutes. Only one generation runs at a time,
and per-session cooldown plus the deployed model quota limit request volume.
The app's in-memory result disappears if the session/container restarts; download
the PNG or use its sharing link before expiry. Generated blobs remain private in
the existing storage account until deleted by its administrator.
