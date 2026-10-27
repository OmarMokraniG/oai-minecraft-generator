const form = document.getElementById("invite-form");
const button = document.getElementById("submit");
const status = document.getElementById("status");
const history = document.getElementById("history");
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

async function api(url, options = {}) {
  const response = await fetch(url, { credentials: "same-origin", ...options });
  const body = await response.json();
  if (!response.ok) {
    const error = new Error(body.error || "No se pudo completar la solicitud.");
    error.status = response.status;
    throw error;
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
    show(error.message, true);
    button.disabled = error.status === 403;
    if (error.status !== 403) timer = setTimeout(poll, 5000);
  }
});

(async () => {
  try {
    const session = await api("/api/session");
    csrf = session.csrf;
    document.getElementById("generator").href = session.generatorUrl;
    await poll();
  } catch (error) {
    show(error.message, true);
  }
})();
