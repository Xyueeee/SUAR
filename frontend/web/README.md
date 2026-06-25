# SUAR Admin Command Console

Static HTML/CSS/JS admin dashboard for the SUAR disaster-response system. No
build step — it talks to the FastAPI backend (`../../backend`) over REST and to
Supabase only for login.

## What's here

```
index.html        single-page app (login + authed shell)
css/styles.css     design system (mirrors the mobile app)
js/config.js       Supabase URL + anon key (public by design)
js/api.js          fetch wrapper (backend base URL + Bearer token)
js/auth.js         Supabase Auth (login / session)
js/app.js          router + shell chrome
js/views/          dashboard, bundles, devices, map, notices, content, prep
```

Views: **Dashboard** (triage tiers, charts, mini map) · **Distress Bundles**
(filter / inspect / edit / delete) · **Devices** · **Map & Danger Zones**
(draw hazard geofences on OpenStreetMap) · **Notices** (advisory broadcasts) ·
**Guides & Tips** (rich-text survival / first-aid / preparation content) ·
**Prep Plans** (nested preparedness checklists with weighted % roll-up).

## First-time setup

### 1. Create the admin user (once)
Supabase Dashboard → **Authentication → Users → Add user**:
- Email + password, tick **Auto Confirm User**.

Then, **security-critical**:
- Add that email to `ADMIN_EMAILS` in `backend/.env` (comma-separated for more
  than one). A valid login is *not* enough — only allowlisted emails reach
  `/admin/*`. Empty list = no admin access (fail closed).
- Disable public sign-up: Supabase Dashboard → **Authentication → Providers →
  Email** → turn **Allow new users to sign up** OFF. The anon key is public, so
  open signup would let anyone obtain a token.

There's no sign-up screen in the console.

### 2. Run the backend
```bash
cd backend
venv/Scripts/python -m uvicorn main:app --port 8000
# or: uvicorn main:app --port 8000
```
`backend/.env` must hold `SUPABASE_URL`, `SUPABASE_SECRET_KEY` (service role),
and `ADMIN_EMAILS` (step 1).

### 3. Expose it (so a browser anywhere can reach it)
```bash
ngrok http 8000
```
Copy the `https://xxxx.ngrok-free.app` URL.

### 4. Open the console
Serve the folder (localStorage/session is more reliable than `file://`):
```bash
cd frontend/web
python -m http.server 5500
```
Open <http://127.0.0.1:5500>. Click the **gear** (bottom-right) → paste the ngrok
URL → **Test & Save**. Then sign in.

The gear's dot is **green** when a backend URL is set, **orange** when not. The
top-bar pill shows live backend reachability.

## Notes

- **Auth model:** the browser logs in against Supabase Auth, then sends the JWT
  to FastAPI, which verifies it and does all data access with the service-role
  key. The web never writes Supabase directly (CLAUDE.md §9).
- **Geofences / notices / content / prep-plans** are stored now; the mobile app
  consuming them (warn-on-entry, in-app notices, offline content) is a later
  increment. Public read endpoints (`GET /notices` etc.) already exist for it.
- **CDN libraries** (Supabase-js, Leaflet, leaflet-draw, Chart.js, Quill) are
  pinned to exact versions. SRI hashes were skipped for this internal FYP tool;
  add `integrity=`/`crossorigin=` if it's ever exposed publicly.
