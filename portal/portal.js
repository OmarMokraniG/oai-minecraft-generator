const form = document.getElementById("invite-form");
const button = document.getElementById("submit");
const status = document.getElementById("status");
const history = document.getElementById("history");
const relogin = document.getElementById("relogin");
const loginUrl = "/.auth/login/aad?post_login_redirect_uri=%2F";
let csrf;
let pendingRequest;
let timer;
let awaitingExecution = sessionStorage.getItem("invitation-execution");

const labels = {
  Succeeded: "Acceso configurado y correo enviado al servicio de entrega",
  Failed: "No se pudo completar. El acceso puede estar creado; revisa los registros de Azure antes de reintentar",
  Stopped: "Operacion detenida",
  Running: "Configurando acceso y enviando instrucciones",
  Processing: "Preparando la invitacion"
};
const terminal = new Set(["Succeeded", "Failed", "Stopped"]);

function show(message, error = false) {
  status.textContent = message;
  status.dataset.error = String(error);
}

function recoverAuthentication(error) {
  if (error.status !== 401 && error.status !== 403) return false;
  clearTimeout(timer);
  button.disabled = true;
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
    row.textContent = `${item.email || item.id}: ${labels[item.status] || `Estado: ${item.status}`}`;
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
    button.disabled = true;
    show(active ? `${active.email}: ${labels[active.status] || active.status}` : "Esperando el estado de Azure...");
    timer = setTimeout(poll, 3000);
  } else if (pendingRequest) {
    button.disabled = false;
    show(`No se ha confirmado la invitacion a ${pendingRequest.email}. Reintenta el envio; se reutilizara la misma solicitud para evitar duplicados.`, true);
    timer = setTimeout(poll, 5000);
  } else {
    button.disabled = false;
    const latest = result.invitations[0];
    if (latest) show(`${latest.email}: ${labels[latest.status] || latest.status}`, latest.status !== "Succeeded");
    else show("Preparado para enviar una invitacion.");
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

form.addEventListener("submit", async event => {
  event.preventDefault();
  button.disabled = true;
  clearTimeout(timer);
  const email = document.getElementById("email").value.trim();
  if (!pendingRequest || pendingRequest.email !== email) {
    pendingRequest = { email, requestId: crypto.randomUUID() };
  }
  show("Iniciando la invitacion...");
  try {
    const execution = await api("/api/invitations", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
      body: JSON.stringify(pendingRequest)
    });
    awaitingExecution = execution.id;
    sessionStorage.setItem("invitation-execution", awaitingExecution);
    pendingRequest = null;
    await refresh();
  } catch (error) {
    if (recoverAuthentication(error)) return;
    show(error.message, true);
    button.disabled = false;
    timer = setTimeout(poll, 5000);
  }
});

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
