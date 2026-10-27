const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "portal", "portal.js"), "utf8");

async function portal(respond, initialStorage = {}) {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      textContent: "", dataset: {}, disabled: true, hidden: true, value: "friend@example.com",
      children: [], listeners: {},
      replaceChildren() { this.children = []; },
      appendChild(child) { this.children.push(child); },
      addEventListener(event, callback) { this.listeners[event] = callback; }
    });
    return elements.get(id);
  }
  const storage = new Map(Object.entries(initialStorage));
  const redirects = [];
  const calls = [];
  const timers = [];
  const context = vm.createContext({
    document: { getElementById: element, createElement: element },
    sessionStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key)
    },
    window: { location: { assign: url => redirects.push(url) } },
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
