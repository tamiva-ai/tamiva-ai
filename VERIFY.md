# v36 — QA-report fix verification

After uploading v36 to your GitHub repo, run these on the worker shell
to confirm each fix actually landed. If any grep returns 0 matches,
that file is still on v35 — re-upload or apply the fix manually.

## 1. Confirm Flutter files are present

```bash
cd /tmp
git clone https://github.com/YOUR_ORG/tamiva-ai.git verify-repo 2>/dev/null || true
cd verify-repo
git pull
```

## 2. Verify the S1 fixes (must land before charging)

```bash
# S1.1 — webhook endpoint exists
grep -n "payments/webhook" backend/src/routes/payments.ts | head -3
# Expected: at least one match for /webhook registration + handler

# S1.1 — payment orders persist server-side
grep -n "prisma.paymentOrder" backend/src/routes/payments.ts | head -3

# S1.1 — self-heal status endpoint exists
grep -n "/status" backend/src/routes/payments.ts

# S1.2 — global session event bus
grep -n "SessionExpired\|SessionEvents" flutter_app/lib/services/api_client.dart

# S1.3 — bootstrap fetch-failure handled
grep -n "_bootstrapFailed" flutter_app/lib/screens/brand_assets_screen.dart

# S1.4 — generation timeout
grep -n "kMaxGenerationDuration\|_generationStartedAt" flutter_app/lib/screens/brand_assets_screen.dart

# S1.5 — DB-backed reset codes
grep -n "passwordResetCode" backend/src/routes/auth.ts | head -3

# S1.6 — payments/order uses x-user-id
grep -n "x-user-id" backend/src/routes/payments.ts | head -3

# S1.6 — payments/verify uses x-user-id
grep -n "x-user-id" backend/src/routes/payments.ts | wc -l
# Expected: 5+ (order + verify + status + createOrderSchema + 401)
```

## 3. Verify the S2 fixes (high-frequency UX)

```bash
# S2.7 — connectivity service exists
ls flutter_app/lib/services/connectivity_service.dart
ls flutter_app/lib/widgets/offline_banner.dart

# S2.8 — cold-start bootstrap + auth state
grep -n "_Bootstrap\|AuthState" flutter_app/lib/main.dart

# S2.9 — corrected 429 copy
grep -n "used your 1 free" flutter_app/lib/errors/user_facing_error.dart

# S2.10 — Upgrade hidden for Pro
grep -n "_isPro\|_tier" flutter_app/lib/screens/brand_assets_screen.dart | head -5

# S2.11 — in-app film player
grep -n "FilmPlaybackService\|VideoPlayer" flutter_app/lib/screens/brand_assets_screen.dart | head -5

# S2.12 — draft store
ls flutter_app/lib/services/draft_store.dart
grep -n "_restoreDraft\|DraftStore" flutter_app/lib/sc