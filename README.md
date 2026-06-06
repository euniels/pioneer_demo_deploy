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

## Important

Do not commit real `.env` files or production secrets. Use `.env.example` and configure environment variables in Render/Vercel.
