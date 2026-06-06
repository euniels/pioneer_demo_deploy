# PioneerPath Flutter Frontend

This Flutter app is now wired to the Laravel backend in the sibling folder:

`C:\Users\Gershan\PIONEER INTEGRATION\pioneer-backend`

## Backend Integration

The frontend now reads live Geotab-backed fleet data from these Laravel routes:

- `GET /api/vehicles`
- `GET /api/vehicles/locations`
- `GET /api/vehicles/{geotabId}/trail`

The shared vehicle store hydrates from Laravel and keeps Geotab vehicles in sync for:

- the vehicles page
- the dashboard fleet counts
- the admin live tracking page
- the driver live tracking page

## Expected Backend Setup

The current Laravel `.env` in the sibling backend is configured for:

- `DB_CONNECTION=sqlite`
- `DB_DATABASE=database/database.sqlite`
- `CACHE_STORE=file`
- `SESSION_DRIVER=file`

It also needs valid Geotab credentials in the backend `.env`.

## Running Both Apps

1. Start the Laravel backend from `pioneer-backend` on port `8000`.
2. Start the Flutter app from this folder.

The frontend defaults to:

- `http://127.0.0.1:8000/api` on desktop and web
- `http://10.0.2.2:8000/api` on Android emulator

If you need a different backend URL, pass:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_HOST:8000
```

## Google Maps

Google Maps is used only as the map renderer. The app draws routes from the
existing backend coordinates and does not call paid Directions, Routes,
Geocoding, or Places APIs.

To avoid accidental API usage, maps stay disabled until a key is supplied:

```bash
flutter run --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY
```

For Flutter web, you can also test with:

```bash
flutter run -d chrome --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY
```

For Android native builds, pass the key through Gradle without committing it:

```bash
$env:ORG_GRADLE_PROJECT_GOOGLE_MAPS_API_KEY="YOUR_KEY"
flutter run -d android --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY
```

For iOS native builds, provide `GOOGLE_MAPS_API_KEY` as a local Xcode build
setting or CI secret so `Info.plist` can pass it to the Google Maps SDK.

Keep the Google Cloud key restricted to the needed app/web origins and only the
Maps JavaScript SDK / Maps SDKs that the target platform uses.

## Notes

- The current workflow intentionally avoids long-running validation commands during active remediation.
- If Laravel is offline, the frontend falls back to its in-memory fleet data instead of crashing.
- Local-only vehicles remain in the store even after Geotab vehicles sync from the backend.
