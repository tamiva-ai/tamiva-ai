# v31 — Tamiva build fixes (FINAL)

This is the final v25 source code + the workflow fix + ChatGPT's
cleaner `MultiSelectSheet` design (uses `selected:` instead of
`initialSelection:`).

## All fixes since v25

| Path | Fix |
|---|---|
| `backend/src/routes/auth.ts` | Removed duplicate `import { prisma }` |
| `flutter_app/lib/models/models.dart` | Renamed `dynamic` parameter to `raw` in `Project.fromJson` |
| `flutter_app/lib/screens/business_info_screen.dart` | `Industries.all` → `kTamivaIndustries`; `BrandTones.all` → `kTamivaBrandTones`; `selected:` → `selected:` (param rename); `maxSelections:` → `maxSelection:` (4 places) |
| `flutter_app/lib/screens/forgot_password_screen.dart` | `userId: userId` → `userId: user.id` |
| `flutter_app/lib/services/api_client.dart` | `_send(http.Request)` → `_send(http.BaseRequest)` to accept MultipartRequest |
| `flutter_app/lib/widgets/multi_select_sheet.dart` | Refactored to use `selected:` (was `initialSelection:`) + `didUpdateWidget` for live updates |
| `backend/prisma/migrations/20260711000000_v24_tier_and_preferences/migration.sql` | (NEW) adds User.tier + tierUpdatedAt + BusinessProfile.palettePreference + fontPreference |
| `.github/workflows/build-apk.yml` | Pin Flutter to 3.24.5 via `flutter-version-file` |
| `.github/flutter-version` | (NEW) contains `3.24.5` |

## Repo layout (v31)

```
backend/         <- Railway API service root (looks for backend/package.json)
flutter_app/     <- GitHub Actions builds APK from this dir
.github/         <- GitHub Actions workflows (build-apk.yml + flutter-version)
README.md
MANIFEST.md
VERIFY.md
```

## How to deploy (4 actions)

1. **Extract** `tamiva-COMPLETE-2026-07-10-v31.zip` on your computer
2. **Open your `tamiva-ai` folder** (cloned via GitHub Desktop)
3. **Drag the inner contents** into that folder (not the outer wrapper)
4. **Commit + push** in GitHub Desktop

## After push

- GitHub Actions builds with Flutter 3.24.5 → APK uploaded as artifact
- Railway redeploys the API service, runs the v24 migration
- After both succeed, app is live

## If the build still fails

Paste the new error. v31 has every fix I've found — if there's a v32
issue it'll be a new bug I haven't seen.
