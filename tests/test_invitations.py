import json
from unittest.mock import MagicMock

import pytest
import requests
from starlette.testclient import TestClient

import invitation_worker
from invitation_service import AccessManager, AzureApi, InvitationJobs, invitation_message
from portal_app import create_app

ADMIN = "11111111-1111-4111-8111-111111111111"
GUEST = "22222222-2222-4222-8222-222222222222"
OPERATION = "33333333-3333-4333-8333-333333333333"
RESOURCE = "/subscriptions/test/resourceGroups/test/providers/Microsoft.App/containerApps/web"
APP_URL = "https://generator.example.com"
PORTAL_URL = "https://portal.example.com"
REDEEM_URL = "https://invitations.microsoft.com/redeem/?tenant=test&user=test"
LOCK = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/test"


def auth(ids=None):
    return {
        "properties": {
            "platform": {"enabled": True},
            "identityProviders": {
                "azureActiveDirectory": {
                    "login": {"loginParameters": ["prompt=select_account", "login_hint=admin"]},
                    "validation": {
                        "defaultAuthorizationPolicy": {
                            "allowedPrincipals": {"identities": ids or [ADMIN]}
                        }
                    },
                }
            },
        }
    }


def app(ids):
    return {
        "properties": {
            "provisioningState": "Succeeded",
            "latestRevisionName": "web-ready",
            "latestReadyRevisionName": "web-ready",
            "template": {
                "containers": [{"env": [{"name": "ALLOWED_USER_IDS", "value": ",".join(ids)}]}]
            },
        }
    }


@pytest.mark.parametrize("new_guest", [False, True])
def test_access_grants_new_and_existing_users_and_verifies_both_controls(new_guest):
    api = MagicMock()
    initial = auth()
    confirmed = auth([ADMIN, GUEST])
    api.arm.side_effect = [initial, {}, app([ADMIN]), {}, app([ADMIN, GUEST]), confirmed]
    api.request.side_effect = (
        [{"value": []}, {"invitedUser": {"id": GUEST}, "inviteRedeemUrl": REDEEM_URL}]
        if new_guest
        else [{"value": [{"id": GUEST}]}]
    )
    manager = AccessManager(api, RESOURCE, ADMIN, APP_URL)
    assert manager.grant("friend@example.com") == (REDEEM_URL if new_guest else None)
    calls = api.arm.call_args_list
    assert calls[1].args == ("PUT", f"{RESOURCE}/authConfigs/current")
    aad = calls[1].kwargs["json"]["properties"]["identityProviders"]["azureActiveDirectory"]
    assert aad["validation"]["defaultAuthorizationPolicy"]["allowedPrincipals"]["identities"] == [
        ADMIN,
        GUEST,
    ]
    assert aad["login"]["loginParameters"] == ["prompt=select_account"]
    assert calls[3].kwargs["json"]["properties"]["template"]["containers"][0]["env"] == [
        {"name": "ALLOWED_USER_IDS", "value": f"{ADMIN},{GUEST}"}
    ]
    if new_guest:
        assert api.request.call_args.kwargs["json"]["sendInvitationMessage"] is False


def test_access_stops_when_admin_is_missing_or_directory_is_ambiguous():
    api = MagicMock()
    api.arm.return_value = auth([GUEST])
    manager = AccessManager(api, RESOURCE, ADMIN, APP_URL)
    with pytest.raises(ValueError, match="administrator"):
        manager.grant("friend@example.com")
    api.request.assert_not_called()
    api.arm.return_value = auth()
    api.request.return_value = {"value": [{"id": ADMIN}, {"id": GUEST}]}
    with pytest.raises(ValueError, match="Multiple"):
        manager.grant("friend@example.com")
    assert all(call.args[0] == "GET" for call in api.arm.call_args_list)


def execution(state="Running", request_id=OPERATION):
    return {
        "name": "invite-abc",
        "properties": {
            "status": state,
            "startTime": "2026-10-27T12:00:00Z",
            "template": {
                "containers": [
                    {
                        "env": [
                            {"name": "INVITED_EMAIL", "value": "friend@example.com"},
                            {"name": "INVITATION_OPERATION_ID", "value": request_id},
                        ]
                    }
                ]
            },
        },
    }


def test_job_start_accepts_real_job_execution_base_response_and_preserves_template():
    api = MagicMock()
    template = {
        "containers": [
            {
                "name": "worker",
                "image": "verified-image",
                "command": ["python", "invitation_worker.py"],
                "imageType": "ContainerImage",
                "resources": {"cpu": 0.5, "memory": "1Gi", "ephemeralStorage": ""},
                "env": [{"name": "AZURE_CLIENT_ID", "value": ADMIN}],
            }
        ],
        "volumes": None,
        "initContainers": None,
    }
    api.arm.side_effect = [
        {"value": []},
        {"properties": {"template": template}},
        {"name": "invite-abc", "id": "/jobs/invite/executions/invite-abc"},
    ]
    jobs = InvitationJobs(api, "/jobs/invite")
    result = jobs.start("friend@example.com", OPERATION)
    assert result["id"] == "invite-abc" and result["status"] == "Processing"
    sent = api.arm.call_args.kwargs["json"]["containers"][0]
    assert sent["image"] == "verified-image"
    assert set(api.arm.call_args.kwargs["json"]) == {"containers"}
    assert "imageType" not in sent
    assert sent["resources"] == {"cpu": 0.5, "memory": "1Gi"}
    assert sent["env"][-2:] == [
        {"name": "INVITED_EMAIL", "value": "friend@example.com"},
        {"name": "INVITATION_OPERATION_ID", "value": OPERATION},
    ]
    assert len(template["containers"][0]["env"]) == 1


def test_job_retries_are_idempotent_and_other_active_execution_blocks_start():
    api = MagicMock()
    api.arm.return_value = {"value": [execution()]}
    jobs = InvitationJobs(api, "/jobs/invite")
    assert jobs.start("friend@example.com", OPERATION)["id"] == "invite-abc"
    with pytest.raises(RuntimeError, match="otra invitacion"):
        jobs.start("friend@example.com", GUEST)
    assert all(call.args[0] == "GET" for call in api.arm.call_args_list)


def test_azure_start_follows_async_location_before_reading_execution_id(monkeypatch):
    api = AzureApi(MagicMock())
    accepted = MagicMock(
        status_code=202,
        headers={"Location": "https://management.azure.com/operation-result", "Retry-After": "0"},
    )
    completed = MagicMock(status_code=200, headers={}, content=b"json")
    completed.json.return_value = {"name": "invite-abc", "id": "/execution"}
    api.session = MagicMock()
    api.session.request.return_value = accepted
    api.session.get.return_value = completed
    monkeypatch.setattr("invitation_service.time.sleep", lambda seconds: None)
    assert api.arm("POST", "/jobs/invite/start")["name"] == "invite-abc"
    assert api.session.get.call_args.args[0] == accepted.headers["Location"]


@pytest.fixture
def portal():
    jobs = MagicMock()
    jobs.executions.return_value = []
    jobs.start.return_value = {"id": "invite-abc", "status": "Processing"}
    access = MagicMock()
    access.users.return_value = {"users": [], "synchronized": True}
    access.describe_user.return_value = {"email": "friend@example.com", "name": "Friend"}
    jobs.revoke.return_value = {"id": "revoke-abc", "status": "Processing", "action": "revoke"}
    client = TestClient(create_app(ADMIN, PORTAL_URL, APP_URL, jobs, access), base_url=PORTAL_URL)
    client.headers["X-Ms-Client-Principal-Id"] = ADMIN
    csrf = client.get("/api/session").json()["csrf"]
    client.headers.update({"Origin": PORTAL_URL, "X-CSRF-Token": csrf})
    return client, jobs


@pytest.mark.parametrize("principal", ["", GUEST])
def test_portal_rejects_anonymous_and_non_admin_without_side_effects(portal, principal):
    client, jobs = portal
    client.headers["X-Ms-Client-Principal-Id"] = principal
    for path in ["/", "/api/session", "/api/invitations", "/api/users"]:
        assert client.get(path).status_code == 403
    assert (
        client.post(
            "/api/invitations", json={"email": "friend@example.com", "requestId": OPERATION}
        ).status_code
        == 403
    )
    jobs.start.assert_not_called()
    jobs.executions.assert_not_called()
    assert (
        client.post(f"/api/users/{GUEST}/revoke", json={"requestId": OPERATION}).status_code == 403
    )
    jobs.revoke.assert_not_called()


@pytest.mark.parametrize("case", ["origin", "csrf", "email", "fields", "uuid", "size"])
def test_portal_rejects_invalid_invitation_requests(portal, case):
    client, jobs = portal
    body = {"email": "friend@example.com", "requestId": OPERATION}
    expected = 400
    if case == "origin":
        client.headers["Origin"] = "https://other.example.com"
        expected = 403
    elif case == "csrf":
        client.headers["X-CSRF-Token"] = "incorrect"
        expected = 403
    elif case == "email":
        body["email"] = "not-an-email"
    elif case == "fields":
        body["command"] = "untrusted override"
    elif case == "uuid":
        body["requestId"] = None
    else:
        body["email"] = "a" * 3000
        expected = 413
    assert client.post("/api/invitations", json=body).status_code == expected
    jobs.start.assert_not_called()


def test_portal_starts_and_reports_explicit_azure_failure(portal):
    client, jobs = portal
    response = client.post(
        "/api/invitations", json={"email": "friend@EXAMPLE.com", "requestId": OPERATION}
    )
    assert response.status_code == 202
    jobs.start.assert_called_once_with("friend@example.com", OPERATION)
    assert response.headers["Cache-Control"] == "no-store"
    jobs.start.side_effect = requests.HTTPError("Azure permission denied")
    assert (
        client.post(
            "/api/invitations", json={"email": "friend@example.com", "requestId": OPERATION}
        ).status_code
        == 502
    )


@pytest.mark.parametrize("failure", [None, "authorization", "email"])
def test_worker_only_reports_success_after_access_verified_and_email_confirmed(
    monkeypatch, capsys, failure
):
    for key, value in {
        "INVITED_EMAIL": "friend@example.com",
        "INVITATION_OPERATION_ID": OPERATION,
        "GENERATOR_URL": APP_URL,
        "GENERATOR_RESOURCE_ID": RESOURCE,
        "ADMIN_USER_ID": ADMIN,
        "ACCESS_LOCK_ID": LOCK,
        "EMAIL_ENDPOINT": "https://email.communication.azure.com",
        "EMAIL_SENDER": "sender@example.com",
    }.items():
        monkeypatch.setenv(key, value)
    manager = MagicMock()
    manager.grant.return_value = REDEEM_URL
    if failure == "authorization":
        manager.grant.side_effect = requests.HTTPError("No authorization")
    monkeypatch.setattr(invitation_worker, "AccessManager", lambda *args: manager)
    monkeypatch.setattr(invitation_worker, "AccessLock", MagicMock())
    monkeypatch.setattr(invitation_worker, "DefaultAzureCredential", MagicMock())
    email = MagicMock()
    email.begin_send.return_value.result.return_value = {
        "status": "Failed" if failure == "email" else "Succeeded"
    }
    email_class = MagicMock()
    email_class.return_value.__enter__.return_value = email
    monkeypatch.setattr(invitation_worker, "EmailClient", email_class)
    assert invitation_worker.run() == (1 if failure else 0)
    result = json.loads(capsys.readouterr().out)
    assert "friend@example.com" not in json.dumps(result)
    if failure == "authorization":
        email_class.assert_not_called()
        assert result["stage"] == "authorization"
    else:
        assert email.begin_send.call_args.kwargs == {"operation_id": OPERATION}
        assert result["status"] == ("failed" if failure else "email_sent")


def test_invitation_email_includes_redeem_and_app_links_and_escapes_recipient():
    message = invitation_message("<friend>@example.com", APP_URL, "sender@example.com", REDEEM_URL)
    assert REDEEM_URL in message["content"]["plainText"]
    assert f"{APP_URL}/.auth/login/aad" in message["content"]["plainText"]
    assert "&lt;friend&gt;" in message["content"]["html"]
    assert "<friend>" not in message["content"]["html"]


@pytest.mark.parametrize("already_removed_from_auth", [False, True])
def test_revoke_updates_both_controls_and_repairs_partial_removal(already_removed_from_auth):
    api = MagicMock()
    initial = auth([ADMIN] if already_removed_from_auth else [ADMIN, GUEST])
    api.arm.side_effect = [initial, {}, app([ADMIN, GUEST]), {}, app([ADMIN]), auth([ADMIN])]
    AccessManager(api, RESOURCE, ADMIN, APP_URL).revoke(GUEST)
    writes = [call for call in api.arm.call_args_list if call.args[0] in {"PUT", "PATCH"}]
    allowed = writes[0].kwargs["json"]["properties"]["identityProviders"]["azureActiveDirectory"][
        "validation"
    ]["defaultAuthorizationPolicy"]["allowedPrincipals"]["identities"]
    assert allowed == [ADMIN]
    assert writes[1].kwargs["json"]["properties"]["template"]["containers"][0]["env"] == [
        {"name": "ALLOWED_USER_IDS", "value": ADMIN}
    ]
    api.request.assert_not_called()
    assert all(call.args[0] != "DELETE" for call in api.arm.call_args_list)


def test_revoke_cannot_remove_administrator_even_before_reading_azure():
    api = MagicMock()
    with pytest.raises(ValueError, match="administrador"):
        AccessManager(api, RESOURCE, ADMIN, APP_URL).revoke(ADMIN)
    api.arm.assert_not_called()
    api.request.assert_not_called()


def test_user_list_reports_partial_permissions_and_deleted_directory_accounts():
    api = MagicMock()
    api.arm.side_effect = [auth([ADMIN, GUEST]), app([ADMIN, OPERATION])]
    response = requests.Response()
    response.status_code = 404
    api.request.side_effect = [
        {"id": ADMIN, "displayName": "Admin", "userPrincipalName": "admin@example.com"},
        {"id": GUEST, "displayName": "Friend", "mail": "friend@example.com"},
        requests.HTTPError(response=response),
    ]
    result = AccessManager(api, RESOURCE, ADMIN, APP_URL).users()
    assert result["synchronized"] is False
    users = {user["id"]: user for user in result["users"]}
    assert users[ADMIN]["hasAccess"] and users[ADMIN]["isAdministrator"]
    assert not users[GUEST]["hasAccess"]
    assert users[OPERATION]["directoryMissing"]
    assert not users[OPERATION]["hasAccess"]
    assert len(users) == 3


def test_directory_permission_failure_is_not_reported_as_a_deleted_user():
    api = MagicMock()
    response = requests.Response()
    response.status_code = 403
    api.request.side_effect = requests.HTTPError(response=response)
    with pytest.raises(requests.HTTPError):
        AccessManager(api, RESOURCE, ADMIN, APP_URL).describe_user(GUEST)


def test_revoke_job_has_no_invitation_email_and_conflicting_retries_are_rejected():
    api = MagicMock()
    api.arm.side_effect = [
        {"value": []},
        {
            "properties": {
                "template": {
                    "containers": [
                        {
                            "name": "worker",
                            "image": "verified-image",
                            "env": [{"name": "INVITED_EMAIL", "value": "stale@example.com"}],
                        }
                    ]
                }
            }
        },
        {"name": "revoke-abc"},
    ]
    jobs = InvitationJobs(api, "/jobs/invite")
    result = jobs.revoke(GUEST, OPERATION, "friend@example.com")
    assert result["action"] == "revoke" and result["userId"] == GUEST
    env = {
        item["name"]: item["value"]
        for item in api.arm.call_args.kwargs["json"]["containers"][0]["env"]
    }
    assert env["ACCESS_USER_ID"] == GUEST
    assert env["ACCESS_ACTION"] == "revoke"
    assert "INVITED_EMAIL" not in env
    api.arm.reset_mock(side_effect=True)
    api.arm.return_value = {"value": [execution()]}
    with pytest.raises(RuntimeError, match="otra operacion"):
        jobs.revoke(GUEST, OPERATION, "friend@example.com")
    assert all(call.args[0] == "GET" for call in api.arm.call_args_list)


@pytest.mark.parametrize("case", ["admin", "invalid-user", "csrf", "extra-field"])
def test_portal_rejects_unsafe_revocations(portal, case):
    client, jobs = portal
    principal = GUEST
    body = {"requestId": OPERATION}
    expected = 403
    if case == "admin":
        principal = ADMIN
    elif case == "invalid-user":
        principal = "not-a-uuid"
        expected = 400
    elif case == "csrf":
        client.headers["X-CSRF-Token"] = "incorrect"
    else:
        body["email"] = "untrusted@example.com"
        expected = 400
    assert client.post(f"/api/users/{principal}/revoke", json=body).status_code == expected
    jobs.revoke.assert_not_called()


def test_portal_starts_durable_revocation_and_lists_access(portal):
    client, jobs = portal
    assert client.get("/api/users").json() == {"users": [], "synchronized": True}
    result = client.post(f"/api/users/{GUEST}/revoke", json={"requestId": OPERATION})
    assert result.status_code == 202
    jobs.revoke.assert_called_once_with(GUEST, OPERATION, "friend@example.com")
    jobs.start.assert_not_called()


@pytest.mark.parametrize("failure", [False, True])
def test_revoke_worker_never_invites_or_sends_mail(monkeypatch, capsys, failure):
    for key, value in {
        "ACCESS_ACTION": "revoke",
        "ACCESS_USER_ID": GUEST,
        "INVITATION_OPERATION_ID": OPERATION,
        "GENERATOR_URL": APP_URL,
        "GENERATOR_RESOURCE_ID": RESOURCE,
        "ADMIN_USER_ID": ADMIN,
        "ACCESS_LOCK_ID": LOCK,
    }.items():
        monkeypatch.setenv(key, value)
    manager = MagicMock()
    if failure:
        manager.revoke.side_effect = requests.HTTPError("Permission update failed")
    monkeypatch.setattr(invitation_worker, "AccessManager", lambda *args: manager)
    monkeypatch.setattr(invitation_worker, "AccessLock", MagicMock())
    monkeypatch.setattr(invitation_worker, "DefaultAzureCredential", MagicMock())
    email = MagicMock()
    monkeypatch.setattr(invitation_worker, "EmailClient", email)
    assert invitation_worker.run() == (1 if failure else 0)
    result = json.loads(capsys.readouterr().out)
    assert result["status"] == ("failed" if failure else "access_revoked")
    manager.revoke.assert_called_once_with(GUEST)
    manager.grant.assert_not_called()
    email.assert_not_called()
