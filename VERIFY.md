# v26 — GitHub repo verification

After uploading v26 to your GitHub repo, run these on the worker shell
to confirm each v25 fix actually landed. If any grep returns 0 matches,
that file is still on v24 — re-upload or apply the fix manually.

## 1. Confirm Flutter files are present (counts)

```bash
cd /tmp
git clone https://github.com/YOUR_ORG/tamiva-ai.git verify-repo 2>/dev/null || true
cd verify-repo
git pull
```

## 2. Verify the 4 critical fixes

```bash
# Fix 1: models.dart - dynamic param renamed to raw
grep -n "Map<String, dynamic> raw" flutter_app/lib/models/models.dart
# Should print: factory Project.fromJson(Map<String, dynamic> raw) {

# Fix 2: business_info_screen.dart - Industries.all → kTamivaIndustries
grep -n "kTamivaIndustries" flutter_app/lib/screens/business_info_screen.dart
# Should print 1+ matches

# Fix 3: business_info_screen.dart - BrandTones.all → kTamivaBrandTones
grep -n "kTamivaBrandTones" flutter_app/lib/screens/business_info_screen.dart
# Should print 1+ matches

# Fix 4: business_info_screen.dart - selected: → initialSelection:
grep -c "initialSelection:" flutter_app/lib/screens/business_info_screen.dart
# Should print 4 (or more)

# Fix 5: business_info_screen.dart - palette mapping
grep -n "PaletteStyles.all.map" flutter_app/lib/screens/business_info_screen.dart
# Should print 1+ matches

# Fix 6: forgot_password_screen.dart - user.id
grep -n "userId: user\\.id" flutter_app/lib/screens/forgot_password_screen.dart
# Should print 1+ matches

# Fix 7: auth.ts - only one prisma import
grep -c "from \"../db/client.js\"" backend/src/routes/auth.ts
# Should print 1 (top of file only - no duplicate mid-file)

# Fix 8: v24 migration exists
ls backend/prisma/migrations/20260711000000_v24_tier_and_preferences/
# Should list: migration.sql
```

## 3. If any grep returns 0 matches

That file is still on v24. Three options:

(a) Re-upload the v26 zip. Sometimes the second upload replaces what
    the first missed.

(b) Edit the file directly in github.dev using the pencil icon. The
    specific line changes are listed at the top of this manifest.

(c) Use curl + the GitHub Contents API to PATCH the file. See
    https://docs.github.com/en/rest/repos/contents#update-file-contents

## 4. Re-run the build

```bash
git commit -am "v26 build fixes" --allow-empty
git push
# GitHub Actions picks up, runs the APK build
```
