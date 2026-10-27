const form = document.getElementById("invite-form");
const button = document.getElementById("submit");
const status = document.getElementById("status");
const history = document.getElementById("history");
const relogin = document.getElementById("relogin");
const userTable = document.getElementById("users");
const usersStatus = document.getElementById("users-status");
const userSearch = document.getElementById("user-search");
const loginUrl = "/.auth/login/aad?post_login_redirect_uri=%2F";
let csrf;
let pendingRequest;
let timer;
let awaitingExecution = sessionStorage.getItem("invitation-execution");
let users = [];
let userButtons = [];
let busy = true;
let usersOperation;

const labels = {
  Succeeded: "Acceso configurado y correo enviado al servicio de entrega",
  Failed: "No se pudo completar. Los permisos pueden haberse actualizado parcialmente; revisa los registros de Azure antes de reintentar",
  Stopped: "Operacion detenida",
  Running: "Configurando acceso y enviando instrucciones",
  Processing: "Preparando la invitacion"
};
const terminal = new Set(["Succeeded", "Failed", "Stopped"]);

function show(message, error = false) {
  status.textContent = message;
  status.dataset.error = String(error);
}

function setBusy(value) {
  busy = value;
  button.disabled = value;
  for (const action of userButtons) action.disabled = value;
}

function operationText(item) {
  const message = item.action === "revoke" && item.status === "Succeeded"
    ? "Acceso revocado (sin eliminar la cuenta)"
    : item.action === "revoke" && !terminal.has(item.status)
      ? "Revocando acceso" : labels[item.status] || `Estado: ${item.status}`;
  return `${item.label || item.email || item.userId || item.id}: ${message}`;
}

function renderUsers() {
  userTable.replaceChildren();
  userButtons = [];
  const query = userSearch.value.trim().toLocaleLowerCase();
  const visible = users.filter(user =>
    `${user.name} ${user.email || ""} ${user.id}`.toLocaleLowerCase().includes(query));
  for (const user of visible) {
    const row = document.createElement("tr");
    const state = user.directoryMissing ? "Cuenta eliminada en Entra"
      : !user.hasAccess ? "Pendiente de sincronizar"
        : user.isAdministrator ? "Administrador" : "Con acceso";
    for (const text of [user.name, user.email || "Sin correo disponible", state]) {
      const cell = document.createElement("td");
      cell.textContent = text;
      row.appendChild(cell);
    }
    const actions = document.createElement("td");
    if (user.isAdministrator) {
      actions.textContent = "Protegido";
      actions.className = "protected";
    } else {
      const revoke = document.createElement("button");
      revoke.type = "button";
      revoke.className = "danger";
      revoke.textContent = "Revocar acceso";
      revoke.disabled = busy;
      revoke.addEventListener("click", () => revokeAccess(user));
      actions.appendChild(revoke);
      userButtons.push(revoke);
    }
    row.appendChild(actions);
    userTable.appendChild(row);
  }
  if (!visible.length) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 4;
    cell.textContent = users.length ? "No hay usuarios que coincidan." : "No hay usuarios.";
    row.appendChild(cell);
    userTable.appendChild(row);
  }
}

async function loadUsers() {
  document.getElementById("refresh-users").disabled = true;
  usersStatus.textContent = "Cargando usuarios...";
  try {
    const result = await api("/api/users");
    if (!Array.isArray(result.users) || typeof result.synchronized !== "boolean") {
      throw new Error("La respuesta de usuarios esta incompleta. Reintenta la consulta.");
    }
    users = result.users;
    renderUsers();
    usersStatus.dataset.error = String(!result.synchronized);
    usersStatus.textContent = result.synchronized
      ? `${users.length} registros de acceso.`
      : "Hay permisos pendientes de sincronizar. Una invitacion o revocacion sincronizara ambos controles.";
  } catch (error) {
    if (recoverAuthentication(error)) return;
    usersStatus.dataset.error = "true";
    usersStatus.textContent = `No se pudieron cargar los usuarios: ${error.message}`;
  } finally {
    document.getElementById("refresh-users").disabled = false;
  }
}

async function revokeAccess(user) {
  if (user.isAdministrator) {
    show("La cuenta administradora esta protegida.", true);
    return;
  }
  const label = user.email || user.name;
  if (!window.confirm(`Revocar el acceso de ${label} a Minecraft Generator? La cuenta no se eliminara de Entra.`)) return;
  if (!pendingRequest || pendingRequest.action !== "revoke" || pendingRequest.userId !== user.id) {
    pendingRequest = { action: "revoke", userId: user.id, label, requestId: crypto.randomUUID() };
  }
  show(`Revocando acceso de ${label}...`);
  await submitOperation(`/api/users/${encodeURIComponent(user.id)}/revoke`, {
    requestId: pendingRequest.requestId
  });
}

function recoverAuthentication(error) {
  if (error.status !== 401 && error.status !== 403) return false;
  clearTimeout(timer);
  setBusy(true);
  relogin.hidden = false;
  show(error.message, true);
  if (error.status === 401) {
    const lastAttempt = Number(sessionStorage.getItem("portal-login-attempt") || 0);
    if (Date.now() - lastAttempt > 60000) {
      sessionStorage.setItem("portal-login-attempt", String(Date.now()));
      window.location.assign(loginUrl);
    }
  }
  return true;
}

async function api(url, options = {}) {
  const response = await fetch(url, {
    credentials: "same-origin",
    redirect: "manual",
    ...options,
    headers: { Accept: "application/json", ...options.headers }
  });
  if (response.status === 401 || response.type === "opaqueredirect") {
    throw Object.assign(new Error("Tu sesion ha caducado. Inicia sesion de nuevo con la cuenta administradora."), { status: 401 });
  }
  const text = await response.text();
  let body;
  if (text.trim()) {
    try {
      body = JSON.parse(text);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
    }
  }
  if (!response.ok) {
    const message = typeof body?.error === "string" ? body.error
      : response.status === 403 ? "No tienes acceso o la sesion necesita renovarse. Inicia sesion con la cuenta administradora."
        : `Azure no pudo completar la solicitud (HTTP ${response.status}). No se ha confirmado la operacion.`;
    throw Object.assign(new Error(message), { status: response.status });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw Object.assign(new Error(`El portal devolvio una respuesta incompleta (HTTP ${response.status}). Recarga la pagina.`), { status: response.status });
  }
  return body;
}

async function refresh() {
  const result = await api("/api/invitations");
  if (pendingRequest && result.invitations.some(item =>
    item.requestId === pendingRequest.requestId && terminal.has(item.status))) {
    pendingRequest = null;
  }
  history.replaceChildren();
  for (const item of result.invitations) {
    const row = document.createElement("li");
    row.textContent = operationText(item);
    history.appendChild(row);
  }
  if (awaitingExecution) {
    const execution = result.invitations.find(item => item.id === awaitingExecution)
      || await api(`/api/invitations/${encodeURIComponent(awaitingExecution)}`);
    if (terminal.has(execution.status)) {
      awaitingExecution = null;
      sessionStorage.removeItem("invitation-execution");
    }
  }
  const active = result.invitations.find(item => !terminal.has(item.status));
  if (active || awaitingExecution) {
    setBusy(true);
    show(active ? operationText(active) : "Esperando el estado de Azure...");
    if (usersOperation === undefined) {
      usersOperation = "active";
      await loadUsers();
    }
    timer = setTimeout(poll, 3000);
  } else if (pendingRequest) {
    setBusy(false);
    const target = pendingRequest.action === "revoke" ? `revocacion de ${pendingRequest.label}`
      : `invitacion a ${pendingRequest.email}`;
    show(`No se ha confirmado la ${target}. Reintenta la operacion; se reutilizara la misma solicitud para evitar duplicados.`, true);
    timer = setTimeout(poll, 5000);
  } else {
    setBusy(false);
    const latest = result.invitations[0];
    if (latest) show(operationText(latest), latest.status !== "Succeeded");
    else show("Preparado para enviar una invitacion.");
    if (usersOperation !== (latest?.id || "initial")) {
      usersOperation = latest?.id || "initial";
      await loadUsers();
    }
  }
}

async function poll() {
  try {
    await refresh();
  } catch (error) {
    if (recoverAuthentication(error)) return;
    show(`${error.message} Se volvera a consultar el estado automaticamente.`, true);
    timer = setTimeout(poll, 5000);
  }
}

async function submitOperation(path, payload) {
  setBusy(true);
  clearTimeout(timer);
  try {
    const execution = await api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
      body: JSON.stringify(payload)
    });
    awaitingExecution = execution.id;
    sessionStorage.setItem("invitation-execution", awaitingExecution);
    pendingRequest = null;
    await refresh();
  } catch (error) {
    if (recoverAuthentication(error)) return;
    show(error.message, true);
    setBusy(false);
    timer = setTimeout(poll, 5000);
  }
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  const email = document.getElementById("email").value.trim();
  if (!pendingRequest || pendingRequest.action !== "invite" || pendingRequest.email !== email) {
    pendingRequest = { action: "invite", email, requestId: crypto.randomUUID() };
  }
  show("Iniciando la invitacion...");
  await submitOperation("/api/invitations", { email, requestId: pendingRequest.requestId });
});

userSearch.addEventListener("input", renderUsers);
document.getElementById("refresh-users").addEventListener("click", loadUsers);

(async () => {
  try {
    const session = await api("/api/session");
    csrf = session.csrf;
    document.getElementById("generator").href = session.generatorUrl;
    await poll();
  } catch (error) {
    if (recoverAuthentication(error)) return;
    show(error.message, true);
  }
})();
