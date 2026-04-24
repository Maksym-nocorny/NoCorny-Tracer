# NoCorny Tracer — Web Platform Deployment

Loom-like web platform at **tracer.nocorny.com** for the NoCorny Tracer macOS app.

The plan that drove this build is in `~/.claude/plans/zazzy-pondering-planet.md`.
The design tokens are documented in `docs/DESIGN_SYSTEM.md` (sourced from `Sources/NoCornyTracer/Theme.swift`).

---

## Architecture (one-paragraph version)

Tracer account is the **primary identity** (email magic link via Resend, or Google OAuth via NextAuth.js v5). Dropbox is **not a login method** — users sign into Tracer first, then optionally connect Dropbox as a storage provider (separate OAuth2 PKCE flow, tokens encrypted at rest with AES-256-GCM). Videos are uploaded to Dropbox by the macOS app, registered with the Tracer backend via `POST /api/videos`, and served publicly at `/v/{slug}` (auto-generated 7-char nanoid). Video playback is a plain HTML5 `<video>` pointed at `dl.dropboxusercontent.com` (we store the `www.dropbox.com` shared URL in the DB and string-replace at render time — no Dropbox API calls on playback). Bi-directional sync: macOS push + Dropbox webhook + daily cron fallback.

---

## External services

| Service | Purpose | Account / Project |
|---|---|---|
| **Vercel** | Hosting (Next.js 16 App Router) | `maksym-nocornys-projects/web` |
| **Neon** | Serverless Postgres | region: eu-central-1, db: `neondb` |
| **Drizzle ORM** | Schema + migrations | `src/lib/db/schema.ts`, run `npx drizzle-kit push` |
| **NextAuth.js v5** | Auth (Google + Resend magic link) | `@auth/drizzle-adapter` |
| **Resend** | Magic link email delivery | domain `nocorny.com` verified |
| **Google Cloud** | OAuth provider | project contains OAuth 2.0 Client |
| **Dropbox** | Storage provider | same app as macOS (app key `uypbk3hdc7zz4l7`) |
| **GoDaddy** | DNS for `nocorny.com` | A record `tracer` → `76.76.21.21` |

### Redirect URIs configured in each provider

- **Google OAuth** → `https://tracer.nocorny.com/api/auth/callback/google`
- **Dropbox OAuth** → `https://tracer.nocorny.com/api/auth/dropbox/callback`
- **macOS app (unchanged)** → `db-uypbk3hdc7zz4l7://oauth2callback` (PKCE, no secret)

---

## Environment variables

All set in Vercel production. Mirrored locally in `web/.env.local` (gitignored).

| Var | Notes |
|---|---|
| `DATABASE_URL` | Neon connection string with `?sslmode=require` |
| `AUTH_SECRET` | NextAuth session secret (32 bytes, base64) |
| `AUTH_URL` | `https://tracer.nocorny.com` |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | From Google Cloud OAuth 2.0 client |
| `AUTH_RESEND_KEY` | Resend API key |
| `EMAIL_FROM` | `NoCorny Tracer <noreply@nocorny.com>` |
| `DROPBOX_APP_KEY` | `uypbk3hdc7zz4l7` (decoded from `Sources/NoCornyTracer/Secrets.swift` XOR obfuscation) |
| `DROPBOX_APP_SECRET` | Server-side only — not stored in the macOS app (which is PKCE public client) |
| `ENCRYPTION_KEY` | 32-byte hex, used by `src/lib/crypto.ts` for AES-256-GCM of Dropbox tokens |

---

## Deployment commands

```bash
cd web

# Push schema changes to Neon
DATABASE_URL="..." npx drizzle-kit push

# Deploy to Vercel production
npx vercel --prod --yes

# Set / override a production env var (⚠️ use printf, NOT echo — see gotchas)
printf "value-no-newline" | npx vercel env add VAR_NAME production --force

# Tail logs
npx vercel logs https://tracer.nocorny.com
```

---

## Gotchas hit during initial deployment

1. **`echo` vs `printf` for env vars.** `echo "value" | vercel env add` appends a trailing `\n` to the stored value. This broke both Google OAuth (`Server error / problem with server configuration`) and Dropbox (`Invalid client_id: "uypbk3hdc7zz4l7\n"`). **Always use `printf` with no `\n`.**

2. **Vercel Hobby cron limit.** Crons must run at most once per day on Hobby plan. Original plan used `*/15 * * * *`; `vercel.json` now uses `0 3 * * *`. Webhook + macOS push remain the real-time sync channels.

3. **DrizzleAdapter + lazy DB proxy incompatibility.** Initial `db/index.ts` used a `Proxy({} as Db, ...)` lazy singleton to avoid throwing at build time when `DATABASE_URL` is missing. This broke `DrizzleAdapter(db)` because `is(db, PgDatabase)` from drizzle-orm checks `instanceof` / prototype chain on the raw value, and a `Proxy({})` doesn't satisfy it. **Fix:** create a real `drizzle()` instance eagerly, with a placeholder fallback URL so `neon()` doesn't throw at build time:
   ```ts
   const sql = neon(process.env.DATABASE_URL ?? "postgresql://none:none@none/none?sslmode=require");
   export const db = drizzle(sql, { schema });
   ```
   Actual queries still fail cleanly at runtime if `DATABASE_URL` isn't set.

4. **Next.js 16 renamed `middleware` → `proxy`.** The file `src/middleware.ts` must be `src/proxy.ts`, and the exported function is `proxy()` not `middleware()`. See `web/AGENTS.md`.

5. **Google OAuth "External" user type.** On personal Google accounts (non-Workspace), the OAuth consent screen defaults to External automatically — no radio button to click.

---

## Current status

- ✅ Deployed at `https://tracer.nocorny.com`
- ✅ Neon schema pushed
- ✅ Google OAuth sign-in working
- ✅ Dropbox OAuth connect (redirect URI added in Dropbox app)
- ✅ Resend domain verified for magic links
- ⏳ macOS app integration — not started (Phase 4 of the plan)

---

## Phase 4 TODO — macOS app integration

See the plan file for details. Summary of what needs to be added to the Swift app:

- `Sources/NoCornyTracer/Services/TracerAuthManager.swift` — browser-based Google OAuth → JWT callback via `nocornytracer://auth/callback`
- `Sources/NoCornyTracer/Services/TracerAPIClient.swift` — HTTP client using JWT from Keychain
- `Recording.swift` — add `tracerSlug: String?` and `tracerURL: String?`; `shareURL` should prefer Tracer URL
- `AppState.processRecording(id:)` — after upload + rename, call `TracerAPIClient.registerVideo()` if signed in
- `SettingsView.swift` — new "Tracer Account" section **above** Dropbox section
- `Info.plist` — register `nocornytracer://` URL scheme
- Backend endpoints needed: `POST /api/auth/device` + `GET /api/auth/device/[code]` for device-code browser auth flow
