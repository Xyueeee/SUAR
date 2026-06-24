/* SUAR admin web — static config.
 *
 * The Supabase URL + anon key are public by design (anon access is gated by
 * Row-Level Security). The FastAPI base URL is NOT here — it's the dynamic
 * ngrok URL the operator sets via the gear icon on the login screen, stored in
 * localStorage under SUAR.BACKEND_URL_KEY. */
window.SUAR = window.SUAR || {};

SUAR.SUPABASE_URL = "https://bnkjjxgrimyzzvjuzndk.supabase.co";
SUAR.SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJua2pqeGdyaW15enp2anV6bmRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE4NTEyODYsImV4cCI6MjA5NzQyNzI4Nn0.LKRgzNU6wLzwAs9ozbV43tX7HNpnpQwoxZXzTBlQ0E8";

SUAR.BACKEND_URL_KEY = "suar_backend_url";

SUAR.getBackendUrl = function () {
  return (localStorage.getItem(SUAR.BACKEND_URL_KEY) || "").replace(/\/+$/, "");
};
SUAR.setBackendUrl = function (url) {
  localStorage.setItem(SUAR.BACKEND_URL_KEY, (url || "").trim().replace(/\/+$/, ""));
};
