# PioneerPath Demo Deploy

Demo monorepo for PioneerPath.

## Folders

- `pioneer-backend/` - Laravel API backend for GeoTab, fleet operations, billing, auth, scheduler, and diagnostics.
- `pioneer_software_integration/` - Flutter web/mobile frontend.

## Demo Deployment

- Backend target: Render
- Frontend target: Vercel
- Mock/demo data can stay enabled for client demo.
- Real production still needs Redis, queue worker, scheduler/cron, backups, and final domain/CORS setup.

## Render Backend

Create the backend first.

- Service type: Web Service
- Runtime: Docker
- Root directory: `pioneer-backend`
- Dockerfile path: `Dockerfile`
- Environment variables: copy from `pioneer-backend/.env.example` and fill real values in the Render dashboard
- Required minimum variables: `APP_KEY`, `APP_ENV=production`, `APP_DEBUG=false`, database settings, JWT settings, CORS/frontend origin, GeoTab settings if testing live fleet data

Do not upload `.env`. Render should store secrets as dashboard environment variables.

After the backend is live, test:

- `/api/health`
- `/api/fleet/geotab/health`
- login
- fleet list endpoints
- billing endpoints

## Vercel Frontend

Deploy the frontend after Render gives you the backend URL.

- Framework preset: Other
- Root directory: `pioneer_software_integration`
- Build command: `bash ./vercel-build.sh`
- Output directory: `build/web`
- Environment variable: `API_BASE_URL=https://your-render-backend.onrender.com`
- Optional demo variable: `PIONEER_SHOW_MOCK_DATA=true`

After Vercel gives you the frontend URL, add that URL to the backend CORS/frontend origin setting on Render and redeploy the backend.

## Important

Do not commit real `.env` files or production secrets. Use `.env.example` and configure environment variables in Render/Vercel.
