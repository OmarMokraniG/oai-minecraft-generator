# ⛏️ Minecraft Character Generator

A web application that generates Minecraft-style character images from text
descriptions or photos. It uses Azure OpenAI for image generation and photo
analysis, stores generated images in Azure Blob Storage, and creates QR codes
for sharing time-limited download links.

## 📋 Features

- Generate a Minecraft-style character from a text description
- Create a character from a photo or webcam capture
- Preview the photo description before generating the image
- Add a decorative frame and download the generated PNG
- Create QR codes and read-only download links that expire after one hour
- Manage authorized users with Microsoft Entra ID
- Invite users by email and review, search or revoke application access
- Keep photos private: resize them, remove metadata and do not store originals

## 🚀 Getting Started

### Prerequisites

- An Azure subscription and permission to create resources and role assignments
- Azure CLI with the Container Apps extension
- Access and quota for the image and vision models in the selected region
- Entra administrator consent for the invitation portal's Microsoft Graph permissions
- Python 3.12 for local development and tests
- Node.js 24 for the invitation portal client tests

### Installation

1. Clone the repository and enter its folder:

   ```powershell
   git clone <repository-url>
   cd <repository-folder>
   ```

2. Install the Python dependencies:

   ```powershell
   python -m venv .venv
   .\.venv\Scripts\python.exe -m pip install -r requirements.txt
   ```

3. Sign in to Azure:

   ```powershell
   az login
   ```

### Configuration

For local development, copy `.env.sample` to `.env` and set:

```dotenv
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com
AZURE_IMAGE_DEPLOYMENT=your-image-deployment
AZURE_VISION_DEPLOYMENT=your-vision-deployment
AZURE_STORAGE_ACCOUNT_URL=https://your-storage.blob.core.windows.net
PUBLIC_DOWNLOAD_BASE_URL=https://your-download-app.azurecontainerapps.io
REQUIRE_AUTH=false
```

The local developer identity needs `Cognitive Services OpenAI User` on the model
resource and `Storage Blob Data Contributor` on the storage account. Production
uses managed identities and Container Apps authentication; do not put API keys
or storage connection strings in `.env`.

## 🖥️ Running the Application

Start the local Streamlit app:

```powershell
.\.venv\Scripts\streamlit.exe run app.py
```

Open the local URL shown by Streamlit. Webcam access requires browser permission
and HTTPS. Production sign-in is restricted to users authorized by the
deployment administrator.

## ☁️ Deploy to Azure

The deployment provisions the resource group, Azure OpenAI account and model
deployments, private StorageV2 account, virtual network and private endpoint,
Container Apps environment, registry, managed identities, and monitoring
workspace in the subscription you choose. It also deploys the generator,
private download gateway, and (by default) an administrator-only invitation
portal and access job. No maintainer subscription, tenant, account or running
application is required; all resources are created in the subscription and tenant
you select.

Choose a subscription and a fresh suffix for globally unique Azure resource
names. Check model availability and quota in your region first:

```powershell
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
.\infra\deploy.ps1 @deployment
```

The signed-in Azure CLI user is the deployment administrator. The script checks
that the Microsoft Graph session matches, creates the resource group and
resources on the first run, deploys the configured models, and prints the
application URLs. Use `-DeploymentAccount <user-principal-name>` to require a
specific signed-in user. Use a new suffix if Azure reports a globally unique
name is unavailable.

By default, the script deploys the image model `gpt-image-2.5-sunburst` and the
vision model `gpt-6.1-sol`. Model versions, regional availability and quota can
change; override `-ImageModel`, `-ImageVersion`, `-VisionModel` and
`-VisionVersion` with deployments available to your subscription.

The storage account is private: public network and anonymous blob access are
disabled. The web app and download gateway reach it through the virtual network
and private endpoint. The QR code contains a read-only HTTPS link that expires
after one hour. The generator does not persist uploaded photos.

Deployment can incur costs for model requests, Container Apps, registry storage,
private networking, Log Analytics, invitation jobs and email. Applications
scale to zero when idle, but some supporting resources continue to incur
charges. Review the resources created in your subscription before deployment.

## ✉️ Manage Application Access

The deployment prints the generator and invitation portal URLs. The portal is
restricted to the deployment administrator. It can invite users, send
instructions, list authorized users and revoke application access without
deleting directory accounts. Invitation email delivery is subject to Azure
Communication Services quotas; acceptance by the email service does not confirm
delivery to or opening by the recipient.

The administrator can also manage access from PowerShell. Use the same
subscription and resource group supplied during deployment:

```powershell
.\infra\access.ps1 -Action List -Subscription $subscription -ResourceGroup $deployment.ResourceGroup
.\infra\access.ps1 -Action Add -Email friend@example.com -Subscription $subscription -ResourceGroup $deployment.ResourceGroup
.\infra\access.ps1 -Action Remove -Email friend@example.com -Subscription $subscription -ResourceGroup $deployment.ResourceGroup
```

Add `-WhatIf` to preview an access operation without changing permissions or
sending an invitation. Removing access does not delete the Entra account.

## 🧪 Testing

Run the Python, portal and Azure script tests:

```powershell
.\.venv\Scripts\ruff.exe check .
.\.venv\Scripts\ruff.exe format --check .
.\.venv\Scripts\python.exe -m pytest -q
node --test .\tests\test_portal_client.cjs
.\tests\test_deploy.ps1
.\tests\test_access.ps1
```

The tests mock Azure operations and do not deploy resources or send real
invitations. `scripts\smoke_test.py` performs live model and storage operations;
it can incur charges and requires a separately configured Azure environment.

## 📁 Repository Structure

- `app.py` — Streamlit interface and generation flow
- `image_generator.py`, `webcam_analyzer.py` — image generation and photo analysis
- `blob_storage_client.py`, `download_app.py` — private image storage and downloads
- `portal/`, `portal_app.py`, `invitation_service.py`, `invitation_worker.py` — access portal and invitations
- `infra/` — Azure deployment and access-management scripts
- `tests/`, `scripts/` — automated tests and operational checks

The original MIT license and copyright notices are retained in `LICENSE`.
