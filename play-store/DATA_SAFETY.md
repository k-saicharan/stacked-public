# Data Safety form answers (Play Console)

**Policy and programs → App content → Data Safety**

## 1. Data collection and security

| Question | Answer |
|----------|--------|
| Does your app collect or share any of the required user data types? | **Yes** (optional anonymous sync) |
| Is all of the user data collected by your app encrypted in transit? | **Yes** (HTTPS to Supabase) |
| Do you provide a way for users to request that their data be deleted? | **Yes** (disable sync or email deviceId) |

## 2. Data types declared

- **App activity → Other actions** (shift summaries: date, shift type, pallets, items, items/hr)
- **Device or other IDs** (anonymous UUID generated on install; not IMEI/MAC)

Local-only notes and SharedPreferences data that never leave the device are **not** declared.

## 3. Per-type details (both types)

| Field | Answer |
|-------|--------|
| Shared with third parties? | **No** |
| Collected ephemerally? | **No** (stored) |
| Required or optional? | **Users can choose** (opt-in sync) |
| Used for | **Analytics** + **App functionality** |
