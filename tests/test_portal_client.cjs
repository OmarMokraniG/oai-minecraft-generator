const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "portal", "portal.js"), "utf8");

async function portal(respond, initialStorage = {}, confirm = () => true) {
  const elements = new Map();
  function newElement() {
    return {
      textContent: "", dataset: {}, disabled: true, hidden: true, value: "",
      children: [], listeners: {},
      replaceChildren() { this.children = []; },
      appendChild(child) { this.children.push(child); },
      addEventListener(event, callback) { this.listeners[event] = callback; }
    };
  }
  function element(id) {
    if (!elements.has(id)) {
      const item = newElement();
      if (id === "email") item.value = "friend@example.com";
      elements.set(id, item);
    }
    return elements.get(id);
  }
  const storage = new Map(Object.entries(initialStorage));
  const redirects = [];
  const calls = [];
  const timers = [];
  const context = vm.createContext({
    document: { getElementById: element, createElement: newElement },
    sessionStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key)
    },
    window: { location: { assign: url => redirects.push(url) }, confirm },
    crypto: { randomUUID: () => "11111111-1111-4111-8111-111111111111" },
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
    clearTimeout: () => {},
    fetch: async (url, options) => {
      calls.push({ url, options });
      return respond(url, options);
    }
  });
  vm.runInContext(source, context);
  await new Promise(resolve => setImmediate(resolve));
  return { element, redirects, calls, timers, context };
}

function normalResponse(url) {
  if (url === "/api/users") return Response.json({ users: [], synchronized: true });
  return Response.json(url === "/api/session"
    ? { csrf: "test-csrf", generatorUrl: "https://generator.example.com" }
    : { invitations: [] });
}

test("an empty EasyAuth 401 renews sign-in instead of attempting JSON parsing", async () => {
  const app = await portal(() => new Response(null, { status: 401 }));
  assert.match(app.element("status").textContent, /sesion ha caducado/);
  assert.equal(app.element("relogin").hidden, false);
  assert.equal(app.element("submit").disabled, true);
  assert.deepEqual(app.redirects, ["/.auth/login/aad?post_login_redirect_uri=%2F"]);
  assert.equal(app.calls[0].options.redirect, "manual");
  assert.equal(app.calls[0].options.headers.Accept, "application/json");
});

test("an unsuccessful renewal shows the login link without a redirect loop", async () => {
  const app = await portal(() => new Response(null, { status: 401 }), {
    "portal-login-attempt": String(Date.now())
  });
  assert.equal(app.redirects.length, 0);
  assert.equal(app.element("relogin").hidden, false);
  assert.match(app.element("status").textContent, /cuenta administradora/);
});

test("a login redirect returned to fetch is handled as an expired session", async () => {
  const app = await portal(() => ({ status: 0, type: "opaqueredirect" }));
  assert.equal(app.redirects.length, 1);
  assert.equal(app.element("relogin").hidden, false);
});

test("an empty 403 explains the access problem and does not keep polling", async () => {
  const app = await portal(() => new Response(null, { status: 403 }));
  assert.match(app.element("status").textContent, /No tienes acceso/);
  assert.equal(app.element("relogin").hidden, false);
  assert.equal(app.timers.length, 0);
});

test("empty or HTML gateway errors retain their HTTP status instead of a JSON error", async () => {
  for (const body of [null, "<html>Bad gateway</html>"]) {
    const app = await portal(url => url === "/api/session" ? normalResponse(url)
      : new Response(body, { status: 502 }));
    assert.match(app.element("status").textContent, /HTTP 502/);
    assert.equal(app.element("status").textContent.includes("<html>"), false);
    assert.equal(app.timers.at(-1).delay, 5000);
  }
});

test("an empty successful response is an explicit incomplete-response error", async () => {
  const app = await portal(() => new Response(null, { status: 200 }));
  assert.match(app.element("status").textContent, /respuesta incompleta/);
  assert.equal(app.element("submit").disabled, true);
});

test("a session expiry during submission triggers sign-in without resubmitting", async () => {
  const app = await portal((url, options) => options.method === "POST"
    ? new Response(null, { status: 401 }) : normalResponse(url));
  assert.equal(app.element("submit").disabled, false);
  await app.element("invite-form").listeners.submit({ preventDefault() {} });
  assert.equal(app.redirects.length, 1);
  assert.equal(app.calls.filter(call => call.options.method === "POST").length, 1);
  assert.equal(app.element("submit").disabled, true);
});

test("an unconfirmed submission is not replaced by an older successful invitation", async () => {
  const app = await portal((url, options) => {
    if (options.method === "POST") return new Response(null, { status: 503 });
    if (url === "/api/session") return normalResponse(url);
    if (url === "/api/users") return normalResponse(url);
    return Response.json({ invitations: [{
      id: "old-invite", email: "older@example.com", status: "Succeeded", requestId: "older"
    }] });
  });

  await app.element("invite-form").listeners.submit({ preventDefault() {} });
  await vm.runInContext("poll()", app.context);
  assert.match(app.element("status").textContent, /No se ha confirmado la invitacion a friend@example.com/);
  assert.equal(app.element("submit").disabled, false);
  assert.equal(app.calls.filter(call => call.options.method === "POST").length, 1);
});

const userRecords = [
  { id: "admin-id", name: "Administrator", email: "admin@example.com", hasAccess: true, isAdministrator: true },
  { id: "guest-id", name: "Friend", email: "friend@example.com", hasAccess: true, isAdministrator: false }
];

function usersResponse(url) {
  return url === "/api/users" ? Response.json({ users: userRecords, synchronized: true }) : normalResponse(url);
}

test("user management protects the administrator and filters by name or email", async () => {
  const app = await portal(usersResponse);
  const rows = app.element("users").children;
  assert.equal(rows.length, 2);
  assert.equal(rows[0].children[3].textContent, "Protegido");
  assert.equal(rows[0].children[3].children.length, 0);
  assert.equal(rows[1].children[3].children[0].textContent, "Revocar acceso");
  app.element("user-search").value = "FRIEND@EXAMPLE";
  app.element("user-search").listeners.input();
  assert.equal(app.element("users").children.length, 1);
  assert.equal(app.element("users").children[0].children[0].textContent, "Friend");
});

test("cancelling the revocation confirmation makes no mutation request", async () => {
  const app = await portal(usersResponse, {}, () => false);
  await app.element("users").children[1].children[3].children[0].listeners.click();
  assert.equal(app.calls.filter(call => call.options.method === "POST").length, 0);
});

test("confirmed revocation posts only a request ID and does not report an email send", async () => {
  let submitted = false;
  const app = await portal((url, options) => {
    if (options.method === "POST") {
      submitted = true;
      return Response.json({ id: "remove-abc", status: "Succeeded", action: "revoke" }, { status: 202 });
    }
    if (submitted && url === "/api/invitations") return Response.json({ invitations: [{
      id: "remove-abc", requestId: "11111111-1111-4111-8111-111111111111",
      status: "Succeeded", action: "revoke", userId: "guest-id", label: "friend@example.com"
    }] });
    return usersResponse(url);
  });
  await app.element("users").children[1].children[3].children[0].listeners.click();
  const posted = app.calls.find(call => call.options.method === "POST");
  assert.equal(posted.url, "/api/users/guest-id/revoke");
  assert.deepEqual(JSON.parse(posted.options.body), { requestId: "11111111-1111-4111-8111-111111111111" });
  assert.match(app.element("status").textContent, /Acceso revocado/);
  assert(!app.element("status").textContent.includes("correo enviado"));
});

test("a user-directory error stays visible instead of becoming an empty successful list", async () => {
  const app = await portal(url => url === "/api/users"
    ? new Response(null, { status: 502 }) : normalResponse(url));
  assert.match(app.element("users-status").textContent, /No se pudieron cargar.*HTTP 502/);
  assert.equal(app.element("users-status").dataset.error, "true");
  assert.equal(app.element("refresh-users").disabled, false);
});
