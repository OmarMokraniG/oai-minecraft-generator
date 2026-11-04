import json
import logging
import os
import sys
from uuid import UUID

import requests
from azure.communication.email import EmailClient
from azure.core.exceptions import AzureError
from azure.identity import DefaultAzureCredential

from invitation_service import (
    AccessLock,
    AccessManager,
    AzureApi,
    https_url,
    invitation_message,
    normalize_email,
)


def run():
    logging.basicConfig(level=logging.WARNING)
    stage = "configuration"
    try:
        action = os.getenv("ACCESS_ACTION", "invite")
        if action not in {"invite", "revoke"}:
            raise ValueError("Unsupported access operation")
        target = (
            normalize_email(os.environ["INVITED_EMAIL"])
            if action == "invite"
            else str(UUID(os.environ["ACCESS_USER_ID"]))
        )
        operation = str(UUID(os.environ["INVITATION_OPERATION_ID"]))
        app_url = https_url(os.environ["GENERATOR_URL"])
        credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
        stage = "authorization"
        manager = AccessManager(
            AzureApi(credential),
            os.environ["GENERATOR_RESOURCE_ID"],
            os.environ["ADMIN_USER_ID"],
            app_url,
        )
        lock = AccessLock(AzureApi(credential), os.environ["ACCESS_LOCK_ID"])
        if action == "revoke":
            with lock:
                manager.revoke(target)
            print(json.dumps({"status": "access_revoked", "operationId": operation}), flush=True)
            return 0
        with lock:
            redeem_url = manager.grant(target)
        stage = "email"
        with EmailClient(https_url(os.environ["EMAIL_ENDPOINT"]), credential) as client:
            result = client.begin_send(
                invitation_message(target, app_url, os.environ["EMAIL_SENDER"], redeem_url),
                operation_id=operation,
            ).result(timeout=180)
        if not result or result.get("status") != "Succeeded":
            raise RuntimeError("The email service did not confirm sending")
        print(json.dumps({"status": "email_sent", "operationId": operation}), flush=True)
        return 0
    except (
        AzureError,
        requests.RequestException,
        ValueError,
        RuntimeError,
        TimeoutError,
        KeyError,
    ) as exc:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "stage": stage,
                    "errorType": type(exc).__name__,
                    "httpStatus": getattr(exc, "status_code", None)
                    or getattr(getattr(exc, "response", None), "status_code", None),
                }
            ),
            flush=True,
        )
        return 1


if __name__ == "__main__":
    sys.exit(run())
