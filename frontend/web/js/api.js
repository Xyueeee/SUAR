/* Thin fetch wrapper around the FastAPI backend.
 * Prepends the operator-set ngrok base URL, attaches the Supabase JWT on every
 * request, and surfaces a typed error so views can show a clean message. */
window.SUAR = window.SUAR || {};

SUAR.ApiError = class extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
};

SUAR.api = (function () {
  async function doFetch(method, path, body, token) {
    const base = SUAR.getBackendUrl();
    const headers = { "ngrok-skip-browser-warning": "true" };
    if (token) headers["Authorization"] = "Bearer " + token;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    return fetch(base + path, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  }

  async function request(method, path, body, _retried) {
    const base = SUAR.getBackendUrl();
    if (!base) {
      throw new SUAR.ApiError("Backend URL not set. Tap the gear on the login screen.", 0);
    }
    const token = await SUAR.auth.getToken();

    let res;
    try {
      res = await doFetch(method, path, body, token);
    } catch (e) {
      throw new SUAR.ApiError("Can't reach the backend. Check the URL and that the server + ngrok are running.", 0);
    }

    if (res.status === 401) {
      // The JWT this request used may just be stale, not actually invalid —
      // supabase-js's background auto-refresh timer gets throttled/paused on
      // backgrounded or long-idle tabs, so the token can expire before that
      // timer ever fires even with the console "in use". One explicit
      // refresh + retry before treating this as a real session expiry.
      if (!_retried) {
        const fresh = await SUAR.auth.refreshToken();
        if (fresh) return request(method, path, body, true);
      }
      SUAR.auth.signOut();
      throw new SUAR.ApiError("Session expired. Please sign in again.", 401);
    }

    let data = null;
    const text = await res.text();
    if (text) {
      try { data = JSON.parse(text); } catch { data = text; }
    }
    if (!res.ok) {
      const detail = data && data.detail ? data.detail : ("Request failed (" + res.status + ")");
      throw new SUAR.ApiError(typeof detail === "string" ? detail : JSON.stringify(detail), res.status);
    }
    return data;
  }

  // Multipart upload (e.g. content images). Sends FormData with the JWT but no
  // JSON Content-Type — the browser sets the multipart boundary itself.
  async function upload(path, file, _retried) {
    const base = SUAR.getBackendUrl();
    if (!base) throw new SUAR.ApiError("Backend URL not set.", 0);
    const token = await SUAR.auth.getToken();
    const headers = { "ngrok-skip-browser-warning": "true" };
    if (token) headers["Authorization"] = "Bearer " + token;
    const fd = new FormData();
    fd.append("file", file);
    let res;
    try {
      res = await fetch(base + path, { method: "POST", headers, body: fd });
    } catch (e) {
      throw new SUAR.ApiError("Upload failed — can't reach the backend.", 0);
    }
    if (res.status === 401) {
      if (!_retried) {
        const fresh = await SUAR.auth.refreshToken();
        if (fresh) return upload(path, file, true);
      }
      SUAR.auth.signOut();
      throw new SUAR.ApiError("Session expired.", 401);
    }
    let data = null; const text = await res.text();
    if (text) { try { data = JSON.parse(text); } catch { data = text; } }
    if (!res.ok) {
      const detail = data && data.detail ? data.detail : ("Upload failed (" + res.status + ")");
      throw new SUAR.ApiError(typeof detail === "string" ? detail : JSON.stringify(detail), res.status);
    }
    return data;
  }

  return {
    get: (p) => request("GET", p),
    post: (p, b) => request("POST", p, b ?? {}),
    patch: (p, b) => request("PATCH", p, b ?? {}),
    del: (p) => request("DELETE", p),
    upload,
    // Plain reachability ping (no auth) for the connection pill.
    async ping() {
      const base = SUAR.getBackendUrl();
      if (!base) return false;
      try {
        const r = await fetch(base + "/health", { headers: { "ngrok-skip-browser-warning": "true" } });
        return r.ok;
      } catch { return false; }
    },
  };
})();
