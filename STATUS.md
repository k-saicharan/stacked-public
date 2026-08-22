---
updated: 2026-08-22
by: Grok
---

## Decided
- Public GitHub version of Stacked lives at https://github.com/k-saicharan/stacked-public.
- Join page is GitHub Pages on the `gh-pages` branch: https://k-saicharan.github.io/stacked-public/
- Public APK is the GitHub Release asset `app-release.apk` (v1.0.7+8). Phones can download it without a GitHub login.
- Source of the signed binary is the private app at `~/Projects/Work /pallet_tracker/` (`com.saicharan.stacked`). This public repo is the distribution surface, not a second product.

## Open
- Play Console internal/closed track still needs the developer account.
- Local AAB rebuild failed on debug-symbol strip; APK is the published artefact.

## Next
- Send the join page URL to people who asked for the app.

## Landmines
- Do not put real shift exports or `backups/` in this public repo.
- Pages is `gh-pages` at `/`, not `/docs` (that folder is the overtime spec).
- Em dashes are prohibited in project writing.
