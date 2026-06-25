Sensor Uplink Aid Response (SUAR) is an Android-based disaster response system developed to address communication breakdowns and inefficient victim prioritisation during large-scale emergencies.

# Instructions
## Backend
### 1. Run the backend
```bash
cd backend; venv/Scripts/python -m uvicorn main:app --port 8000
```
`backend/.env` must hold `SUPABASE_URL`, `SUPABASE_SECRET_KEY` (service role),
and `ADMIN_EMAILS`.

### 2. Expose it (if backend to be accessed from a different device)
```bash
ngrok http 8000
```
Copy the `https://xxxx.ngrok-free.app` URL.

## Web
### 1. Run the console
```bash
cd frontend/web; python -m http.server 5500
```
Open <http://127.0.0.1:5500>. Click the **gear** (bottom-right) → paste the ngrok
URL → **Test & Save**. Then sign in (http://127.0.0.1:8000 if same device with backend).

The gear's dot is **green** when a backend URL is set, **orange** when not. The
top-bar pill shows live backend reachability.

## Mobile
```bash
cd frontend/mobile; flutter clean; flutter pub get; flutter run
```
Ensure an android device is connected with usb setting set as **file transfer** with **wireless/usb debugging** enabled.

Open "Settings > Debugging Options > Backend Sync URL" then paste the ngrok URL and save to connect the app with backend.