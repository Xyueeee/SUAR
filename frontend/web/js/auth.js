/* Supabase Auth wrapper. The ONLY place the web talks to Supabase directly —
 * everything else goes through the FastAPI backend. supabase-js persists the
 * session in localStorage, so a refresh keeps you signed in. */
window.SUAR = window.SUAR || {};

SUAR.auth = (function () {
  const client = window.supabase.createClient(SUAR.SUPABASE_URL, SUAR.SUPABASE_ANON_KEY);

  return {
    client,

    async signIn(email, password) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw new Error(error.message);
      return data;
    },

    // silent=true: caller will render the login screen itself (with a message),
    // so don't show the blank login here and double-render.
    async signOut(silent) {
      try { await client.auth.signOut(); } catch (_) {}
      if (!silent && SUAR.app) SUAR.app.showLogin();
    },

    async getSession() {
      const { data } = await client.auth.getSession();
      return data.session;
    },

    async getToken() {
      const session = await this.getSession();
      return session ? session.access_token : null;
    },

    async getUserEmail() {
      const session = await this.getSession();
      return session && session.user ? session.user.email : null;
    },

    // Re-validate against the backend allowlist (not just "is there a session").
    // Throws SUAR.ApiError on 401/403/503/network so the caller can react.
    async verifyAdmin() {
      const me = await SUAR.api.get("/admin/me");
      return me && me.email ? me.email : null;
    },
  };
})();
