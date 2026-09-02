# Project Activity Log: Stacked (Public Version)

## 2026-09-02 (later)

### Stepped join page + CI
- Join page is now email → help improve → download, one card at a time.
- Fixed `unawaited_return_in_try_block` in `lib/storage.dart` so Flutter CI can go green.
- Site/docs no longer trigger the Flutter workflow.

## 2026-09-02

### Strip landing page + QR
- Join page is now download, thanks, three optional agrees, and email. No extra copy.
- Emails go to Gmail via formsubmit so a paused Supabase project cannot swallow signups.
- QR (`site/qr.png`) encodes https://k-saicharan.github.io/stacked-public/
- Operator display: https://k-saicharan.github.io/stacked-public/show.html

## 2026-08-22

### Public APK + join page
- Hosted the join page on GitHub Pages (`gh-pages` branch): https://k-saicharan.github.io/stacked-public/
- Published signed `app-release.apk` (v1.0.7+8) as a public GitHub Release so sideload does not hit a login wall.
- Join page `CONFIG.apkUrl` now points at `https://github.com/k-saicharan/stacked-public/releases/latest/download/app-release.apk`.
- Verified unauthenticated download: HTTP 200, Android package MIME, ~50.5 MB.

## 2026-08-08

### Public Repository Wrangling & Tone Alignment
- Audited repository for sensitive credentials, personal contact information, external document links, and negative/adversarial copy.
- Created project status surface `STATUS.md` and activity log `log.md`.
- Re-framed all project copy (README.md, LISTING.md, site/index.html, docs, Dart source code, and tests) from defensive/pessimistic language to empowering, constructive operational tracking.
- Replaced negative example notes ("dock delay", "forklift queue", "system down", "slow shift") with professional operational notes ("stock replenishment", "equipment check", "task transition").
- Updated shift target math explanations and UI descriptions from "management yardstick" to "daily target benchmark".
- Replaced privacy-defensive comments ("prevent CCTV/badge matching") with clear privacy statements ("preserve user privacy with aggregated summary metrics").
- Replaced hardcoded contact emails and private Google Doc privacy policy links with clean public placeholders and local privacy resources.
- Eliminated all em dashes across the codebase and documentation to adhere strictly to project writing standards.
- Created public GitHub repository and pushed `main` branch: [k-saicharan/stacked-public](https://github.com/k-saicharan/stacked-public).

