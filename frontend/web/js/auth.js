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
      if (error) {
        // supabase-js can't reach Supabase Cloud at all (DNS/firewall/offline)
        // and wraps that as AuthRetryableFetchError with message "Failed to
        // fetch" — easy to mistake for a bad password, but it's a network
        // problem: unlike the FastAPI backend (which can run fully local),
        // Supabase Auth always needs real internet access.
        if (error.name === "AuthRetryableFetchError" || /failed to fetch/i.test(error.message)) {
          throw new Error("Can't reach the sign-in service — this needs internet access (the backend can be local/offline, but Supabase Auth can't). Check your connection and try again.");
        }
        throw new Error(error.message);
      }
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

    // supabase-js's autoRefreshToken runs on a background timer that browsers
    // throttle/pause for backgrounded or long-idle tabs — leave the console
    // open in a background tab past the JWT's expiry and the token goes stale
    // before that timer ever fires. One explicit refresh attempt, used by
    // api.js right before it would otherwise sign out on a 401.
    async refreshToken() {
      try {
        const { data, error } = await client.auth.refreshSession();
        if (error || !data.session) return null;
        return data.session.access_token;
      } catch (_) {
        return null;
      }
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
