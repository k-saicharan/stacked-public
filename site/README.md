# Stacked join page (pilot)

Public-facing + admin tools for the Android pilot.

| File | Purpose |
|------|---------|
| [`index.html`](index.html) | Public: collect Google email + APK download |
| [`admin.html`](admin.html) | **You only:** export emails → paste into Play Console |
| [`supabase_schema.sql`](supabase_schema.sql) | Base tables / RLS / manager view |
| [`supabase_export_notify.sql`](supabase_export_notify.sql) | Export RPC + optional Discord/Slack notify |

## Where emails actually go (2026-09-02)

Join-page signups are **not** in Supabase. That project is paused; the hostname does not resolve.

They go to **Gmail** `saicharan9977@gmail.com` via FormSubmit (subject `Stacked pilot signup`). First submit sent an activation mail. After activate, each signup is an inbox message with email / play_tester / share_totals / pilot_email. Search: `from:formsubmit.co subject:"Stacked pilot signup"`.

The phone also keeps the last typed address in `localStorage.stacked_pilot_email`. That is on-device only.

The `pilot_signups` table and `admin.html` still exist for when Supabase is resumed. Do not treat them as live.

## Data flow (live)

```
Tester fills join page
        │
        ▼
  FormSubmit → Gmail 9977     ← live store (inbox, not a table)
        │
        ▼
  Copy emails into Play Console tester list
```

Play Console cannot be fully auto-filled without the heavy Play Developer API. This stack gets you as close as is practical for a pilot.

## One-time backend setup

### 1) Base schema (if not already done)

Supabase → SQL Editor → run [`supabase_schema.sql`](supabase_schema.sql)  
(If you already applied the column patch for `items_per_hour_live`, skip re-running the full file unless you want idempotent re-apply.)

### 2) Export + notify

Run [`supabase_export_notify.sql`](supabase_export_notify.sql).

Then set your secret (and optional webhook):

```sql
update public.pilot_config
set
  export_secret = 'REPLACE_WITH_LONG_RANDOM_SECRET',  -- openssl rand -hex 24
  notify_webhook_url = null,  -- or 'https://discord.com/api/webhooks/...'
  updated_at = now()
where id = 1;
```

**Discord webhook:** Server settings → Integrations → Webhooks → New Webhook → Copy URL.  
Every new signup posts a short message with the email.

### 3) Confirm insert still works

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  'https://eaywswtmjdzgogxvmebt.supabase.co/rest/v1/pilot_signups' \
  -H "apikey: $STACKED_ANON_KEY" \
  -H "Authorization: Bearer $STACKED_ANON_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{"email":"you@gmail.com","source":"manual-test"}'
# expect 201 (or 409 if that email already exists)
```

## Using admin (Play paste loop)

1. Open `admin.html` (same host as join page, or local file).
2. Enter the export secret → **Load signups**.
3. **Copy new only** → paste into Play Console → Testing → Internal/Closed → email list.
4. Click **Mark new as exported** so they drop out of the “new” box next time.

## Host the pages

Static files only. Cloudflare Pages / Netlify / open locally.  
Keep `admin.html` unlisted (security is the secret, not obscurity; still don’t post the admin URL publicly with the secret).

## APK link

Private GitHub Releases need a logged-in GitHub account. For real phones, set a public mirror in `index.html` → `CONFIG.apkUrl`, or put the Play Internal opt-in URL in `CONFIG.playOptInUrl`.

## App data (shift totals)

| Layer | Behaviour |
|-------|-----------|
| Device | Full logs + notes always local |
| Consent Yes | HTTPS POST to `sessions` (anonymous shift totals) |
| Never in `sessions` | Notes, name, email, wall-clock log times |

## After each release

1. Grab `app-release.apk` from [Releases](https://github.com/k-saicharan/stacked/releases/latest)  
2. Update public `CONFIG.apkUrl` if needed  
3. Share join page URL to recruit  
