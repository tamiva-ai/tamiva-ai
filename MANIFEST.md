# v33 — Razorpay Pro payments, email normalization, price fix

Built 2026-07-13 on top of v32.

## ⚠️ Required Railway env vars (payments won't work without these)
Set on the backend service in Railway → Variables:
- `RAZORPAY_KEY_ID`   — your Razorpay **key id** (rzp_live_… or rzp_test_…)
- `RAZORPAY_KEY_SECRET` — your Razorpay **key secret** (server-only; never in the app or repo)
- `RAZORPAY_PRO_AMOUNT_PAISE` — optional, defaults to `500000` (₹5000)

If the key vars are unset, `/payments/*` returns a clean 503 and the app shows
"Payments aren't set up yet" instead of crashing. **Regenerate the secret if it
was ever pasted into a chat/message.**

## Fixes in v33

| Path | Fix |
|---|---|
| `backend/src/routes/payments.ts` | (NEW) `POST /payments/order` (creates a ₹5000 Razorpay order; accepts userId OR businessProfileId) and `POST /payments/verify` (HMAC signature check, then flips tier→pro). Secret read from env only. |
| `backend/src/index.ts` | Mounts `paymentsRouter` at `/payments`. |
| `backend/package.json` | Added `razorpay` SDK. |
| `backend/src/routes/auth.ts` | Email normalization: `normalizeEmail` + case-insensitive `findUserByEmail` used across signup, login, forgot-password, reset. Fixes mixed-case emails being treated as different/missing users. |
| `flutter_app/lib/services/payment_service.dart` | (NEW) Wraps razorpay_flutter checkout in a Future; verifies server-side. |
| `flutter_app/lib/services/api_client.dart` | `createRazorpayOrder` + `verifyRazorpayPayment` + `RazorpayOrder` model. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | Pro price ₹499→₹5000; Upgrade button now runs real checkout; locked-tile hint retexted. |
| `flutter_app/lib/screens/business_info_screen.dart` | Upgrade button runs real Razorpay checkout; removed the dead mock-payment screen. |
| `flutter_app/pubspec.yaml` | Added `razorpay_flutter`. |

## Watch on first deploy
- **Backend build**: first build with the `razorpay` SDK (types). If tsc complains about razorpay types, tell me and I'll add a shim.
- **APK build**: first build with `razorpay_flutter` (native). CI scaffolds Android unminified, so no ProGuard rules needed — but this is the step to watch.
- **Email casing**: existing mixed-case rows are matched case-insensitively (no data migration); brand-new signups are stored lowercased.

---

# v32 — Auth UX, logo display, quota race & download fixes

Built 2026-07-13 on top of v31. Six fixes from the last session
(re-applied — the prior session hit a token limit before producing a zip).

## Fixes in v32

| Path | Fix |
|---|---|
| `backend/src/routes/auth.ts` | Login returns 404 "This email isn't registered." for unknown email (wrong password still 401). Forgot-password returns 404 for unknown email and sends no code (was: always `{sent:true}`). |
| `backend/src/routes/projects.ts` | `enforceFreeQuota` now counts `queued+generating+ready` (not just `ready`), closing the race that spawned duplicate logos. Failed projects excluded so retries work. |
| `flutter_app/lib/widgets/net_image.dart` | (NEW) Drop-in for `CachedNetworkImage` that also renders `data:` (base64) URLs via `Image.memory`. Fixes logos not displaying. |
| `flutter_app/lib/services/asset_saver.dart` | (NEW) Saves image assets (data: or http) to the device gallery via `gal`. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | All 7 `CachedNetworkImage`→`NetImage`; save-to-gallery buttons on logo+carousel viewers, open-in-browser on film viewer; cost dialog copy ("1 Free generation", carousel ~~₹150~~ struck); removed auto-generation on mount — now bootstraps existing logo or shows a manual "Generate your logo" CTA. |
| `flutter_app/pubspec.yaml` | Added `gal: ^2.3.0`. |
| `.github/workflows/build-apk.yml` | Inject `WRITE_EXTERNAL_STORAGE` (maxSdkVersion 28) for gal on older Android. |

## Known follow-ups (not in this build)
- Email casing is inconsistent: forgot-password lowercases lookups; signup/login don't. A mixed-case signup email could get a false "not registered" on reset. Normalize emails to fix.
- First build with `gal` (first native plugin beyond image_picker/url_launcher) — watch the CI Gradle step.

---

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
