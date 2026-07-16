Sensor Uplink Aid Response (SUAR) is an Android-based disaster response system developed to address communication breakdowns and inefficient victim prioritisation during large-scale emergencies.

# Prerequisites

- **Git**
- **Python 3.10+** (backend)
- **Flutter SDK** (mobile app) — includes the Dart SDK
- **Android Studio** or standalone **Android SDK/platform-tools** (for `adb`, emulator, or a physical device)
- **ngrok** (optional, only needed to reach the backend from a phone or browser on another machine/network)
- A **Supabase** project (URL + service-role key + anon/publishable key)

# 1. Clone the repository

```bash
git clone <repo-url> SUAR
cd SUAR
```

# 2. Backend setup (FastAPI)

### 2.1 Create and activate a virtual environment

```bash
cd backend
python -m venv venv
```

Activate it:
- **Windows (PowerShell):** `venv\Scripts\Activate.ps1`
- **Windows (cmd):** `venv\Scripts\activate.bat`
- **macOS/Linux:** `source venv/bin/activate`

### 2.2 Install dependencies

```bash
pip install -r requirements.txt
```

### 2.3 Configure environment variables

Create a `backend/.env` file (not committed to git) with:

```
SUPABASE_URL=<your Supabase project URL>
SUPABASE_SECRET_KEY=<your Supabase service-role key>
SUPABASE_PUBLISHABLE_KEY=<your Supabase anon/publishable key>

API_HOST=0.0.0.0
API_PORT=8000

# Comma-separated emails allowed to use /admin/* (the web console).
# Must match a user created in Supabase Auth. Empty = no admin access (fail closed).
ADMIN_EMAILS=your-admin-email@example.com
```

### 2.4 Run the backend

```bash
cd backend; venv/Scripts/python -m uvicorn main:app --port 8000
# or, with the venv activated: uvicorn main:app --port 8000
```

### 2.5 Expose it (only if the web console or app run on a different device)

```bash
ngrok http 8000
```

Copy the `https://xxxx.ngrok-free.app` URL, you'll paste it into the web console and/or the mobile app.

# 3. Web admin console (frontend/web)

No build step and no dependencies to install, it's static HTML/CSS/JS served directly.

### 3.1 Create the admin user (once)

In the Supabase Dashboard: **Authentication → Users → Add user**, tick **Auto Confirm User**. Then add that email to `ADMIN_EMAILS` in `backend/.env` (step 2.3) and restart the backend. Also disable public sign-up under **Authentication → Providers → Email** (the anon key is public, so open signup would let anyone obtain a token).

### 3.2 Serve the console

```bash
cd frontend/web; python -m http.server 5500
```

Open <http://127.0.0.1:5500>. Click the **gear** icon (bottom-right), paste the backend URL (the ngrok URL, or `http://127.0.0.1:8000` if the backend runs on the same machine), then **Test & Save**. Sign in with the admin user created above.

The gear's dot is **green** when a backend URL is set, **orange** when not. The top-bar pill shows live backend reachability.

# 4. Mobile app (frontend/mobile)

### 4.1 Install dependencies

```bash
cd frontend/mobile
flutter clean
flutter pub get
```

### 4.2 Connect a device

Connect an Android device over USB with **file transfer** mode and **USB debugging** enabled (or start an emulator/Android Studio virtual device). Confirm it's visible with:

```bash
flutter devices
```

### 4.3 Run the app

```bash
flutter run
```

### 4.4 Connect the app to the backend

Once launched, open **Settings → Debugging Options → Backend Sync URL**, paste the ngrok URL (or local backend URL), and save.

# Notes

- Two devices are needed to exercise the full mesh flow: one running in **Victim** mode and one in **Helper** mode.
- The backend, web console, and mobile app can all be run in parallel on separate terminals once each is set up.
