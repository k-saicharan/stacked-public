# Stacked join page (pilot)

Public-facing + admin tools for the Android pilot.

| File | Purpose |
|------|---------|
| [`index.html`](index.html) | Public: collect Google email + APK download |
| [`admin.html`](admin.html) | Admin view: export emails for Play Console testing list |
| [`supabase_schema.sql`](supabase_schema.sql) | Base tables / RLS / summary views |
| [`supabase_export_notify.sql`](supabase_export_notify.sql) | Export RPC + optional notification webhooks |

## Data flow (automated parts)

```
Tester fills join page
        │
        ▼
  pilot_signups (Supabase)     ← automated
        │
        ├─► Discord/Slack webhook  ← automated if notify_webhook_url set
        │
        ▼
  admin.html → Copy new emails   ← one click
        │
        ▼
  Play Console tester list       ← paste into Play Console
        │
        ▼
  Mark as exported               ← updates export tracking status
```

Play Console tester management can be updated via batch email export. This stack provides a streamlined onboarding workflow.

## One-time backend setup

### 1) Base schema

Supabase -> SQL Editor -> run [`supabase_schema.sql`](supabase_schema.sql)

### 2) Export + notify

Run [`supabase_export_notify.sql`](supabase_export_notify.sql).

Set configuration parameters:

```sql
update public.pilot_config
set
  export_secret = 'REPLACE_WITH_LONG_RANDOM_SECRET',  -- openssl rand -hex 24
  notify_webhook_url = null,  -- optional webhook URL
  updated_at = now()
where id = 1;
```

### 3) Confirm insert endpoint

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  'https://YOUR_PROJECT.supabase.co/rest/v1/pilot_signups' \
  -H "apikey: $STACKED_ANON_KEY" \
  -H "Authorization: Bearer $STACKED_ANON_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{"email":"user@example.com","source":"manual-test"}'
# expect 201 (or 409 if email already exists)
```

## Admin workflow

1. Open `admin.html`.
2. Enter the export secret -> **Load signups**.
3. **Copy new only** -> paste into Play Console testing list.
4. Click **Mark new as exported**.

## Hosting

Deploy as static HTML to Cloudflare Pages, Netlify, or your preferred host.

## App data (shift totals)

| Layer | Behavior |
|-------|-----------|
| Device | Full logs + notes stored locally |
| Consent Yes | HTTPS POST to `sessions` (anonymous shift totals) |
| Never in `sessions` | Notes, name, email, wall-clock log times |
