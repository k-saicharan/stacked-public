-- Stacked backend : run once in Supabase SQL Editor
-- Project: YOUR_PROJECT
--
-- Fixes:
--   1) sessions INSERT so the app can post consented shift totals
--   2) pilot_signups for the join page (Play Console tester emails)
--   3) manager aggregate view for analysis (no per-device monitoring surface)
--
-- Encryption / privacy contract:
--   - In transit: HTTPS (TLS) only from app + landing page
--   - At rest: Supabase disk encryption
--   - App payload is anonymized (random device_id, no name/email/notes)
--   - Landing page stores email only for Play Console opt-in (separate table)

-- ── 1) Sessions table (telemetry from consented installs) ───────────────────
-- If the table already exists, this is a no-op shape check.
create table if not exists public.sessions (
  id bigserial primary key,
  device_id text not null,
  session_date date not null,
  shift_type text not null,
  pallets int,
  total_items int,
  total_stops int,
  items_per_stop double precision,
  avg_stops_per_pallet double precision,
  duration_hours double precision,
  rotation_role text,
  items_per_hour int,
  items_per_hour_live int,
  app_version text,
  created_at timestamptz not null default now()
);

-- If sessions already existed from an older schema, add missing columns.
alter table public.sessions
  add column if not exists total_stops int,
  add column if not exists items_per_stop double precision,
  add column if not exists avg_stops_per_pallet double precision,
  add column if not exists duration_hours double precision,
  add column if not exists rotation_role text,
  add column if not exists items_per_hour int,
  add column if not exists items_per_hour_live int,
  add column if not exists app_version text,
  add column if not exists created_at timestamptz default now();

create index if not exists sessions_device_date_idx
  on public.sessions (device_id, session_date desc);

alter table public.sessions enable row level security;

-- Drop stale policies so re-runs are safe
drop policy if exists "public_insert_sessions" on public.sessions;
drop policy if exists "anon_insert_sessions" on public.sessions;
drop policy if exists "Allow anonymous inserts" on public.sessions;

-- App uses publishable (anon) key : must allow INSERT for role anon.
create policy "public_insert_sessions"
  on public.sessions
  for insert
  to anon, authenticated
  with check (true);

-- No public SELECT. Read only via service role / SQL editor / locked views.
drop policy if exists "public_select_sessions" on public.sessions;

-- ── 2) Pilot signups (join page emails → Play Console list) ─────────────────
create table if not exists public.pilot_signups (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  source text not null default 'landing',
  created_at timestamptz not null default now(),
  constraint pilot_signups_email_nonempty check (length(trim(email)) > 3)
);

-- Dedupe on case-insensitive email
create unique index if not exists pilot_signups_email_lower
  on public.pilot_signups (lower(trim(email)));

alter table public.pilot_signups enable row level security;

drop policy if exists "public_insert_pilot_signups" on public.pilot_signups;

create policy "public_insert_pilot_signups"
  on public.pilot_signups
  for insert
  to anon, authenticated
  with check (true);

-- No public SELECT : pull emails only from the Supabase Table Editor or:
--   select email from pilot_signups order by created_at;
-- Paste into Play Console → Testing → email lists.

-- ── 3) Manager analysis view (aggregates only) ──────────────────────────────
create or replace view public.shift_macro_summary_view as
select
  session_date,
  shift_type,
  count(distinct device_id) as active_pickers_sample,
  count(*) as total_sessions_logged,
  sum(total_items) as total_items_picked,
  sum(pallets) as total_pallets_logged,
  round(avg(items_per_hour_live)::numeric, 1) as avg_live_pace_items_per_hr,
  round(avg(duration_hours)::numeric, 2) as avg_shift_span_hrs
from public.sessions
group by session_date, shift_type
order by session_date desc, shift_type;

-- ── 4) Quick self-test (optional; safe to leave) ────────────────────────────
-- After running, from a terminal:
-- curl -s -X POST 'https://YOUR_PROJECT.supabase.co/rest/v1/sessions' \
--   -H "apikey: <PUBLISHABLE_KEY>" \
--   -H "Authorization: Bearer <PUBLISHABLE_KEY>" \
--   -H "Content-Type: application/json" \
--   -H "Prefer: return=minimal" \
--   -d '{"device_id":"self-test","session_date":"2026-01-01","shift_type":"morning","pallets":0,"total_items":0,"items_per_hour":0,"app_version":"sql-self-test"}'
-- Expect HTTP 201. Then delete the self-test row from Table Editor.
