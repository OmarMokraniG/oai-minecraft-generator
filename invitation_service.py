import copy
import html
import logging
import threading
import time
from urllib.parse import urlparse
from uuid import UUID

import requests
from azure.core.exceptions import AzureError
from email_validator import validate_email

ARM = "https://management.azure.com"
GRAPH = "https://graph.microsoft.com/v1.0"
API_VERSION = "2025-01-01"
STORAGE_API_VERSION = "2023-05-01"
LEASE_SECONDS = 60
LEASE_RENEWAL_SECONDS = 20
LEASE_WAIT_SECONDS = 300
TERMINAL_STATES = {"Succeeded", "Failed", "Stopped"}
logger = logging.getLogger(__name__)


def normalize_email(value):
    if not isinstance(value, str) or len(value) > 254:
        raise ValueError("Introduce un correo valido.")
    return validate_email(value.strip(), check_deliverability=False).normalized


def https_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("A valid HTTPS URL is required")
    return value.rstrip("/")


def user_ids(values, administrator):
    ids = {str(UUID(value)) for value in values}
    if str(UUID(administrator)) not in ids or str(UUID(int=0)) in ids:
        raise ValueError("The administrator must remain in the authorization policy")
    return sorted(ids)


class AzureApi:
    def __init__(self, credential):
        self.credential = credential
        self.session = requests.Session()

    def request(self, method, url, **kwargs):
        parsed = urlparse(url)
        host = parsed.hostname
        if parsed.scheme != "https" or host not in {"management.azure.com", "graph.microsoft.com"}:
            raise ValueError("Unsupported Azure API destination")
        scope = (
            "https://management.azure.com/.default"
            if host == "management.azure.com"
            else "https://graph.microsoft.com/.default"
        )
        response = self.session.request(
            method,
            url,
            headers={"Authorization": f"Bearer {self.credential.get_token(scope).token}"},
            timeout=(10, 60),
            **kwargs,
        )
        response.raise_for_status()
        deadline = time.monotonic() + 120
        while response.status_code == 202 and response.headers.get("Location"):
            if time.monotonic() >= deadline:
                raise TimeoutError("Azure is still starting the invitation job")
            location = response.headers["Location"]
            if (
                urlparse(location).scheme != "https"
                or urlparse(location).hostname != "management.azure.com"
            ):
                raise ValueError("Unexpected Azure operation status destination")
            time.sleep(min(int(response.headers.get("Retry-After", "3")), 10))
            response = self.session.get(
                location,
                headers={"Authorization": f"Bearer {self.credential.get_token(scope).token}"},
                timeout=(10, 60),
            )
            response.raise_for_status()
        return response.json() if response.content else {}

    def arm(self, method, resource, **kwargs):
        return self.request(method, f"{ARM}{resource}?api-version={API_VERSION}", **kwargs)


class AccessLock:
    def __init__(self, api, lock_id):
        self.api = api
        self.url = f"{ARM}{lock_id}/lease?api-version={STORAGE_API_VERSION}"
        self.stopped = threading.Event()
        self.lease_id = None
        self.renewal = None

    def lease(self, **body):
        return self.api.request("POST", self.url, json=body)

    def __enter__(self):
        deadline = time.monotonic() + LEASE_WAIT_SECONDS
        while True:
            try:
                self.lease_id = self.lease(action="Acquire", leaseDuration=LEASE_SECONDS)["leaseId"]
                break
            except requests.HTTPError as error:
                if error.response is None or error.response.status_code != 409:
                    raise
            if time.monotonic() >= deadline:
                raise TimeoutError("Another access update is still running")
            time.sleep(5)
        self.renewal = threading.Thread(target=self.renew, daemon=True)
        self.renewal.start()
        return self

    def renew(self):
        while not self.stopped.wait(LEASE_RENEWAL_SECONDS):
            try:
                self.lease(action="Renew", leaseId=self.lease_id)
            except (AzureError, requests.RequestException) as exc:
                logger.warning("Could not renew the access lock: %s", type(exc).__name__)

    def __exit__(self, *details):
        self.stopped.set()
        self.renewal.join()
        try:
            self.lease(action="Release", leaseId=self.lease_id)
        except (AzureError, requests.RequestException) as exc:
            logger.warning("Could not release the access lock: %s", type(exc).__name__)


class AccessManager:
    def __init__(self, api, resource_id, administrator, app_url):
        self.api = api
        self.resource_id = resource_id
        self.administrator = str(UUID(administrator))
        self.app_url = https_url(app_url)

    def authorization(self):
        auth = self.api.arm("GET", f"{self.resource_id}/authConfigs/current")["properties"]
        if not auth["platform"]["enabled"]:
            raise ValueError("Application authentication must be enabled")
        aad = auth["identityProviders"]["azureActiveDirectory"]
        policy = aad["validation"]["defaultAuthorizationPolicy"]
        allowed = user_ids(policy["allowedPrincipals"]["identities"], self.administrator)
        return auth, allowed

    def describe_user(self, principal):
        principal = str(UUID(principal))
        try:
            profile = self.api.request(
                "GET",
                f"{GRAPH}/users/{principal}",
                params={"$select": "id,displayName,mail,userPrincipalName"},
            )
        except requests.HTTPError as error:
            if error.response is None or error.response.status_code != 404:
                raise
            logger.warning("Authorized directory identity no longer exists: %s", principal)
            return {
                "id": principal,
                "name": "Cuenta eliminada en Entra",
                "email": None,
                "isAdministrator": principal == self.administrator,
                "directoryMissing": True,
            }
        if str(UUID(profile["id"])) != principal:
            raise ValueError("Directory identity does not match the requested user")
        upn = profile.get("userPrincipalName") or ""
        email = profile.get("mail") or (upn if "#ext#" not in upn.lower() else None)
        return {
            "id": principal,
            "name": profile.get("displayName") or email or principal,
            "email": email,
            "isAdministrator": principal == self.administrator,
            "directoryMissing": False,
        }

    def users(self):
        _, allowed = self.authorization()
        env = self.api.arm("GET", self.resource_id)["properties"]["template"]["containers"][0][
            "env"
        ]
        value = next(
            (item.get("value", "") for item in env if item["name"] == "ALLOWED_USER_IDS"), ""
        )
        runtime = {str(UUID(item)) for item in value.split(",") if item}
        users = []
        for principal in sorted(set(allowed) | runtime):
            user = self.describe_user(principal)
            user["hasAccess"] = principal in allowed and principal in runtime
            users.append(user)
        users.sort(key=lambda user: (not user["isAdministrator"], user["name"].casefold()))
        return {"users": users, "synchronized": set(allowed) == runtime}

    def revoke(self, principal):
        principal = str(UUID(principal))
        if principal == self.administrator:
            raise ValueError("No se puede revocar el acceso del administrador.")
        auth, allowed = self.authorization()
        self.synchronize(auth, [item for item in allowed if item != principal])

    def grant(self, recipient):
        auth, allowed = self.authorization()
        literal = recipient.replace("'", "''")
        users = self.api.request(
            "GET",
            f"{GRAPH}/users",
            params={
                "$filter": f"mail eq '{literal}' or userPrincipalName eq '{literal}'",
                "$select": "id,mail,userPrincipalName",
            },
        )
        matches = users["value"]
        if len(matches) > 1 or users.get("@odata.nextLink"):
            raise ValueError("Multiple directory accounts match this email")
        redeem_url = None
        if matches:
            principal = str(UUID(matches[0]["id"]))
        else:
            invitation = self.api.request(
                "POST",
                f"{GRAPH}/invitations",
                json={
                    "invitedUserEmailAddress": recipient,
                    "inviteRedirectUrl": f"{self.app_url}/.auth/login/aad?post_login_redirect_uri=%2F",
                    "sendInvitationMessage": False,
                },
            )
            principal = str(UUID(invitation["invitedUser"]["id"]))
            redeem_url = https_url(invitation["inviteRedeemUrl"])
            if urlparse(redeem_url).hostname not in {
                "login.microsoftonline.com",
                "invitations.microsoft.com",
            }:
                raise ValueError("Unexpected invitation redemption host")
        self.synchronize(auth, [*allowed, principal])
        return redeem_url

    def synchronize(self, auth, values):
        auth_id = f"{self.resource_id}/authConfigs/current"
        allowed = user_ids(values, self.administrator)
        aad = auth["identityProviders"]["azureActiveDirectory"]
        policy = aad["validation"]["defaultAuthorizationPolicy"]
        policy["allowedPrincipals"]["identities"] = allowed
        login = aad.setdefault("login", {})
        parameters = [
            item
            for item in login.get("loginParameters", [])
            if not item.startswith("prompt=")
            and (len(allowed) == 1 or not item.startswith("login_hint="))
        ]
        login["loginParameters"] = [*parameters, "prompt=select_account"]
        self.api.arm("PUT", auth_id, json={"properties": auth})

        app = self.api.arm("GET", self.resource_id)
        template = copy.deepcopy(app["properties"]["template"])
        env = template["containers"][0].setdefault("env", [])
        current = next((item for item in env if item["name"] == "ALLOWED_USER_IDS"), None)
        if current is None or sorted(current.get("value", "").split(",")) != allowed:
            if current is None:
                env.append({"name": "ALLOWED_USER_IDS", "value": ",".join(allowed)})
            else:
                current["value"] = ",".join(allowed)
            self.api.arm("PATCH", self.resource_id, json={"properties": {"template": template}})
        self.wait_ready(allowed)
        updated = self.api.arm("GET", auth_id)["properties"]["identityProviders"][
            "azureActiveDirectory"
        ]["validation"]["defaultAuthorizationPolicy"]["allowedPrincipals"]["identities"]
        if user_ids(updated, self.administrator) != allowed:
            raise RuntimeError("Authorization changed concurrently; inspect access before retrying")

    def wait_ready(self, allowed, timeout=360):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            properties = self.api.arm("GET", self.resource_id)["properties"]
            state = properties["provisioningState"]
            if state in {"Failed", "Canceled"}:
                raise RuntimeError("Application access update failed")
            env = properties["template"]["containers"][0]["env"]
            value = next(
                (item.get("value", "") for item in env if item["name"] == "ALLOWED_USER_IDS"), ""
            )
            if (
                state == "Succeeded"
                and sorted(value.split(",")) == allowed
                and properties.get("latestReadyRevisionName")
                and properties["latestReadyRevisionName"] == properties.get("latestRevisionName")
            ):
                return
            time.sleep(3)
        raise TimeoutError("Application access update is still pending")


def invitation_message(recipient, app_url, sender, redeem_url=None):
    app_url = https_url(app_url)
    login_url = f"{app_url}/.auth/login/aad?post_login_redirect_uri=%2F"
    steps = []
    if redeem_url:
        steps.append(f"1. Acepta la invitacion de Microsoft: {https_url(redeem_url)}")
    steps.extend(
        [
            f"Abre Minecraft Generator: {app_url}",
            f"Inicia sesion con {recipient}. Enlace directo: {login_url}",
            "Si aparece otra cuenta Microsoft, elige Usar otra cuenta. Acepta los permisos "
            "de entrada al directorio si Microsoft lo solicita.",
            "Escribe una descripcion o usa Desde una foto. Para una foto, marca el permiso "
            "y captura o sube una imagen: Lo que ve la IA mostrara su descripcion.",
            "Pulsa Generar personaje o Crear desde la foto. Puede tardar uno o dos minutos.",
            "Descarga el PNG o comparte el QR. El enlace del QR caduca en una hora.",
            "No necesitas permisos de Azure ni acceso a GitHub. Si acabas de recibir "
            "la invitacion y aparece acceso denegado, espera un minuto y vuelve a entrar.",
        ]
    )
    text = "Ya tienes acceso a Minecraft Generator.\n\n" + "\n\n".join(steps)
    links = f'<p><a href="{html.escape(login_url, quote=True)}">Abrir Minecraft Generator</a></p>'
    if redeem_url:
        links = (
            f'<p><a href="{html.escape(redeem_url, quote=True)}">Aceptar invitacion Microsoft</a></p>'
            + links
        )
    return {
        "senderAddress": sender,
        "recipients": {"to": [{"address": recipient}]},
        "content": {
            "subject": "Tu acceso a Minecraft Generator",
            "plainText": text,
            "html": "<html><body><h1>Tu acceso a Minecraft Generator</h1>"
            + links
            + "".join(f"<p>{html.escape(step)}</p>" for step in steps)
            + "</body></html>",
        },
        "userEngagementTrackingDisabled": True,
    }


class InvitationJobs:
    def __init__(self, api, resource_id):
        self.api = api
        self.resource_id = resource_id
        self.lock = threading.Lock()

    def executions(self):
        page = self.api.arm("GET", f"{self.resource_id}/executions")
        executions = page["value"]
        while page.get("nextLink"):
            page = self.api.request("GET", page["nextLink"])
            executions.extend(page["value"])
        return sorted(
            executions, key=lambda item: item["properties"].get("startTime") or "", reverse=True
        )

    @staticmethod
    def summary(execution):
        properties = execution["properties"]
        env = properties.get("template", {}).get("containers", [{}])[0].get("env", [])
        values = {item["name"]: item.get("value", "") for item in env}
        return {
            "id": execution["name"],
            "status": properties.get("status", "Unknown"),
            "email": values.get("INVITED_EMAIL", ""),
            "requestId": values.get("INVITATION_OPERATION_ID", ""),
            "started": properties.get("startTime"),
            "action": values.get("ACCESS_ACTION", "invite"),
            "userId": values.get("ACCESS_USER_ID", ""),
            "label": values.get("ACCESS_USER_LABEL") or values.get("INVITED_EMAIL", ""),
        }

    def start(self, email, request_id):
        return self.start_operation("invite", email, request_id, email)

    def revoke(self, principal, request_id, label):
        return self.start_operation("revoke", str(UUID(principal)), request_id, label)

    def start_operation(self, action, target, request_id, label):
        with self.lock:
            existing = [self.summary(item) for item in self.executions()]
            duplicate = next((item for item in existing if item["requestId"] == request_id), None)
            if duplicate:
                previous = duplicate["userId"] if action == "revoke" else duplicate["email"]
                if duplicate["action"] != action or previous.casefold() != target.casefold():
                    raise RuntimeError(
                        "Esta solicitud corresponde a otra operacion. Recarga el portal."
                    )
                return duplicate
            if any(item["status"] not in TERMINAL_STATES for item in existing):
                raise RuntimeError(
                    "Hay otra invitacion u operacion de acceso en curso. Espera a que termine."
                )
            source = self.api.arm("GET", self.resource_id)["properties"]["template"]
            template = copy.deepcopy(
                {key: source[key] for key in ("containers", "initContainers") if source.get(key)}
            )
            for containers in template.values():
                for container in containers:
                    for key in list(container):
                        if key not in {"name", "image", "command", "args", "env", "resources"}:
                            del container[key]
                    if "resources" in container:
                        container["resources"] = {
                            key: value
                            for key, value in container["resources"].items()
                            if key in {"cpu", "memory"}
                        }
            env = template["containers"][0].setdefault("env", [])
            env[:] = [
                item
                for item in env
                if item["name"]
                not in {
                    "INVITED_EMAIL",
                    "INVITATION_OPERATION_ID",
                    "ACCESS_ACTION",
                    "ACCESS_USER_ID",
                    "ACCESS_USER_LABEL",
                }
            ]
            env.extend(
                [
                    {"name": "ACCESS_ACTION", "value": action},
                    {"name": "ACCESS_USER_LABEL", "value": label},
                    {
                        "name": "INVITED_EMAIL" if action == "invite" else "ACCESS_USER_ID",
                        "value": target,
                    },
                    {"name": "INVITATION_OPERATION_ID", "value": request_id},
                ]
            )
            execution = self.api.arm("POST", f"{self.resource_id}/start", json=template)
            return {
                "id": execution["name"],
                "status": "Processing",
                "email": target if action == "invite" else "",
                "action": action,
                "userId": target if action == "revoke" else "",
                "label": label,
                "requestId": request_id,
                "started": None,
            }
