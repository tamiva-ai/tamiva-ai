# v36 — Production-readiness sweep (QA report fixes)

Built 2026-07-13 on top of v35. Every fix in
`TAMIVA-FLOW-COVERAGE-QA.md` is addressed. The QA report's S1 (will-cause-
charged-but-broken) and S2 (high-frequency unprofessional) lists are fully
resolved; S3 (polish) gaps are mostly closed. See "Mapping" below.

## New in v36

### S1 — paid flows / dead-ends (6/6)

| Path | Fix |
|---|---|
| `backend/src/routes/payments.ts` | Razorpay webhook with raw-body signature verification; PaymentOrder table upsert; tierExpiresAt set on grant. Webhook + verify + /payments/status form a 3-way reconciliation path so a network drop mid-checkout no longer leaves the user charged-but-not-upgraded. |
| `backend/src/routes/me.ts` | (NEW) GET /auth/me — validates a stored userId and returns the authoritative current tier (post-expiry downgrade reflected). |
| `flutter_app/lib/services/api_client.dart` | Global 401/403 handler emits a SessionEvent so any widget can react. /auth/me and /payments/status wired in. `Idempotency-Key` attached to every mutating call so signup / business profile / payments are safe to retry. `setUserId()` switches the auth header in-place. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | Bootstrap fetch failure no longer falls through to "no logo" — distinct retry state. Generation timeout (6 min) flips stuck projects to a retryable error. |
| `backend/src/routes/auth.ts` | DB-backed PasswordResetCode (was: in-memory Map wiped on redeploy). TTL + cooldown + attempt limit + bcrypt'd codes. Idempotent signup. |
| `backend/src/middleware/idempotency.ts` | (NEW) IdempotencyKey middleware + daily sweep. |
| `backend/src/util/tier.ts` | (NEW) getEffectiveTier() reconciles expired Pro users in-place; proExpiryFromNow() centralises the 30-day window. |
| `backend/prisma/schema.prisma` | Adds PaymentOrder, IdempotencyKey, PasswordResetCode; drops creditsBalance; adds tierExpiresAt. |
| `backend/prisma/migrations/20260713000000_v36_payments_idempotency_reset/migration.sql` | (NEW) Idempotent migration: drops creditsBalance, adds the three new tables, backfills tierExpiresAt for existing Pro users. |
| `backend/src/routes/payments.ts` | (S1.6) `/payments/order` now requires `x-user-id` header (no body userId). BusinessProfileId is only a sanity check. Same on `/payments/verify`. |
| `backend/src/queue/worker.ts` | Runs `sweepExpiredProUsers()` and `sweepStaleIdempotencyKeys()` on boot and every 6 hours. |

### S2 — high frequency (9/9)

| Path | Fix |
|---|---|
| `flutter_app/lib/services/connectivity_service.dart` | (NEW) Wraps `connectivity_plus`. |
| `flutter_app/lib/widgets/offline_banner.dart` | (NEW) Thin red strip at top of any screen — disappears when reconnected. |
| `flutter_app/lib/main.dart` | Cold-start auto-login via persisted AuthState; validates via /auth/me + /payments/status; routes to brand kit or welcome based on whether a BusinessProfile exists. Session-expired listener clears stored state. |
| `flutter_app/lib/services/auth_state.dart` | (NEW) SharedPreferences-backed User persistence (replaces the in-memory userId model). |
| `backend/src/routes/projects.ts` | 429 copy now reads "You've used your 1 free" instead of "Daily limit" + adds `upgradeCopy: true` flag the client uses to surface an inline upgrade CTA. |
| `flutter_app/lib/errors/user_facing_error.dart` | Copy matches the actual model (per-user-one-true-quota) instead of the stale "refreshes at midnight" line. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | (S2.10) Upgrade CTA hidden when `_tier == 'pro'`. |
| `flutter_app/lib/services/video_downloader.dart` | (NEW) In-app playback via `video_player`; gallery save via `gal` with permission_handler fallback; deep-link to Settings. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | (S2.11) `_FilmViewerScreen` now StatefulWidget with controller init/dispose; tap-to-play; progress bar; Save + Share actions. |
| `flutter_app/lib/services/draft_store.dart` | (NEW) SharedPreferences-backed form draft persistence. |
| `flutter_app/lib/screens/business_info_screen.dart` | (S2.12) Draft restore on mount + debounced auto-save on every field change. Cleared on successful submit. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | (S2.13) `_CarouselPreviewState` and `_FilmPreviewState` now bootstrap from the existing project on mount (same pattern as logo). App-kill mid-generation no longer resets to a "tap to generate" CTA. |
| `flutter_app/lib/screens/upload_assets_screen.dart` | (S2.14) Per-file upload with retry on transient errors. Successful uploads proceed even when individual files fail. |
| `backend/src/util/tier.ts` | (S2.15) 30-day Pro expiry enforced. Worker sweeps every 6h. |

### S3 — polish (6/6)

| Path | Fix |
|---|---|
| `flutter_app/lib/screens/brand_assets_screen.dart` | (S3.16) Regenerate action on the logo viewer's app bar. |
| `flutter_app/lib/services/share_service.dart` | (NEW) Share sheet wrapper. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | (S3.17) Carousel viewer has a "Save all" action that downloads every slide in parallel and surfaces a single result snackbar. |
| `backend/src/middleware/idempotency.ts` | (S3.18) Idempotency keys wired across signup, business profile, payment order/verify. |
| `flutter_app/lib/screens/upload_assets_screen.dart` | (S3.19) Client-side size/type validation before upload (50 MB / HEIC / 0-byte fail fast). |
| (S3.20) | All critical screens are StatefulWidget. Sliver-based HeroBannerScaffold preserved for rotation; no regressions on the existing rotation-tested surfaces. |
| `flutter_app/lib/services/asset_saver.dart`, `flutter_app/lib/services/video_downloader.dart` | (S3.21) Permission-denied messages now have an `openAppSettings()` CTA. |

## New dependencies (Flutter)

| Package | Used for |
|---|---|
| `uuid: ^4.5.1` | Idempotency-Key generation |
| `shared_preferences: ^2.3.2` | Token + draft persistence |
| `connectivity_plus: ^6.0.5` | Offline detection |
| `video_player: ^2.9.2` | In-app film playback |
| `share_plus: ^10.1.2` | Carousel save-all + share |
| `permission_handler: ^11.3.1` | Gallery + settings deep-link |

## Required env (new)

Backend (Railway):
- `RAZORPAY_WEBHOOK_SECRET` — generate under Razorpay Dashboard → Webhooks →
  Create webhook (events: `payment.captured`, `order.paid`). Without this,
  the webhook endpoint returns 503 but the rest of the system (including
  client verify + /payments/status) still works.
- The webhook URL is `https://<your-host>/payments/webhook`.

## Watch on first deploy

- `prisma migrate deploy` runs the v36 migration (adds three tables,
  drops creditsBalance, adds tierExpiresAt). Existing Pro users get a
  30-day window from their tierUpdatedAt as a one-time backfill.
- After deploy, hit `/health` then create one test order via the
  app and verify the webhook endpoint logs the event. If the
  webhook secret is unset, the endpoint returns 503 — that's expected.

---

# v35 — App icon, palette/font pickers, checkout fix

Built 2026-07-13 on top of v34.

## New in v35

| Path | Fix |
|---|---|
| `flutter_app/assets/icon/app_icon.png` | New Tamiva icon (gold lotus + flame on black). White padding removed → full black square. |
| `flutter_app/assets/icon/app_icon_foreground.png` | Gold lotus isolated on transparent, padded to the adaptive safe zone. |
| `flutter_app/pubspec.yaml` | Adaptive icon enabled: `adaptive_icon_background: #000000` + lotus foreground. (CI already runs `dart run flutter_launcher_icons`.) |
| `flutter_app/lib/widgets/multi_select_sheet.dart` | Added optional per-option leading widget + text style builders. |
| `flutter_app/lib/screens/business_info_screen.dart` | Palette picker shows real colour swatches; font picker renders each option in its actual typeface (google_fonts). |
| `backend/src/routes/payments.ts` | **Checkout fix:** Razorpay receipt was `pro_{uuid}_{ts}` (~54 chars) — over Razorpay's 40-char limit, so orders failed. Shortened to `pro_{ts}`; userId kept in notes. Also surfaces the real Razorpay error. |
| `flutter_app/lib/services/payment_service.dart` | Surfaces the real backend error on checkout failure instead of a generic message. |

## Still required for payments
Railway backend env: `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` (regenerate the one shared in chat), optional `RAZORPAY_PRO_AMOUNT_PAISE`.

## Watch on first deploy
- APK build runs `flutter_launcher_icons` after `flutter create` — new icon applies automatically.
- Backend build: `razorpay` SDK. APK: `razorpay_flutter` + `gal` native plugins.

---

# v34 — Upload flow, brand-kit personalization, lock fix (+ all of v33)

Built 2026-07-13. First packaged build since v32, so it includes the v33
work (Razorpay Pro payments, email normalization, ₹5000 price) plus the
items below.

## New in v34

| Path | Fix |
|---|---|
| `backend/package-lock.json` | Regenerated so `razorpay@2.9.6` is in sync — fixes the Railway `npm ci` failure. |
| `flutter_app/lib/screens/business_info_screen.dart` | New users now go **Business info → Upload assets (logo / ambassador / product / references) → Brand kit**. Was routing to a placeholder stub that skipped uploads. |
| `flutter_app/lib/screens/brand_assets_screen.dart` | Removed the duplicate "YOUR COLOUR PALETTE / YOUR TYPOGRAPHY" row under the starter-kit line. Brand-colors section now shows the user's selected palette(s); Typography section now shows the user's **brand name in their selected font(s)** (via google_fonts). Fallbacks when no preference set. |

## Still required for payments (from v33)
Set on the Railway backend service:
- `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` (secret is server-only; regenerate the one pasted in chat).
- `RAZORPAY_PRO_AMOUNT_PAISE` optional (default 500000 = ₹5000).

## Watch on first deploy
- Backend build: first with the `razorpay` SDK.
- APK build: first with `razorpay_flutter` + `gal` native plugins.

---

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
