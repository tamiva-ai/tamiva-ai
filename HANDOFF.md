# Tamiva Android Handoff — for the next chat session

## What's working (do not regress)

1. **Sign-up duplicate-account dialog.** Tapping "Start free" with an already-registered email or phone shows an **"Account already exists"** dialog with a "Reset password" / "Sign in" action. Verified working on real device.

2. **AGP 8.7.3 → 8.9.1** because AndroidX libraries (`androidx.navigationevent:1.0.2`, `core:1.18.0`, `activity:1.12.4`, `browser:1.9.0`) require it. Gradle wrapper bumped to 8.11.1.

3. **Keystore path fixed.** Uses `rootProject.file(...)` so the keystore resolves from `flutter_app/android/`, not the app subdir.

4. **`isShrinkResources` removed from release block.** AGP 8.9.x quirk.

5. **Tag-driven versioning.** CI computes next `vN.M.K` from existing git tags, builds with `--build-name=X --build-number=Y`, pushes the tag. Race-handling retry (up to 5 attempts) handles parallel AAB + APK builds on the same push.

6. **"BRAND TONE (Pick one)"** label updated in `business_info_screen.dart`.

7. **Stepper UX on "About your business".** Industry → Brand Tone → Typography → Palette auto-advance; Continue button appears after palette is picked.

8. **Required-field validation.** Empty business name or industry shows inline red error.

9. **Palette/font keys** stored as keys (not displayNames) so backend lookups resolve correctly.

10. **Backend `PALETTE_HEX` + `FONT_CATEGORY_DESC`** extended to all 21 entries each.

11. **Hardened signup response parser.** Defensive `is String` checks in `_userFromAuthBody`; signup() validates response shape before parsing and throws real `ApiException` on malformed bodies.

12. **In-app diagnostic code stripped** — production code path. No `_diagStatus`/`_diagBody` fields, no orange panel.

## What was wrong and why

| Symptom | Root cause | Fix |
|---|---|---|
| Build failure: "Removing unused resources requires unused code shrinking" | AGP 8.9.x interprets `isShrinkResources = false` as "I'm opting in to the shrinker path" | Removed the line entirely; defaults to false |
| Build failure: "AndroidX library requires AGP 8.9.1" | Flutter 3.44.6 plugins pull `url_launcher_android:6.3.x` → `androidx.navigationevent:1.0.2` (and similar) which declare `min-agp 8.9.1` | Bumped AGP |
| Build failure: "Could not find package 'platforms-android-35'" | YAML block scalar kept newlines; sdkmanager saw one giant package name | Single-line, quoted `packages:` string + correct name (`platforms;android-35` with semicolon) |
| Tag race: "v0.1.1 already exists" | Two workflows ran concurrently from one push, both computed `v0.1.1`, lost race | Retry loop in `Push Version Tag` step (up to 5 attempts), re-runs `next-version.sh` if push fails |
| Keystore not found in `:app:validateSigningRelease` | `file(...)` resolved relative to app subdir | Changed to `rootProject.file(...)` |
| Play Console: "version code already used" | Hardcoded `versionCode = 2` collides when re-uploading | Removed hardcoded values; CI computes from git tags |
| Play Console: "doesn't allow existing users to upgrade" | New minSdk=24 (Flutter 3.44 default) too high for existing users | Pinned `minSdk = 21` |
| Sign-up: dialog never fired | Initial matcher had `e.statusCode == 409` check; backend sometimes returns 200 with malformed body instead; matcher did not see it | Matcher now checks body content, including the synthetic "Malformed auth response" body from defensive validation |
| Black screen on "About your business" | `ListView` inside `SliverToBoxAdapter` renders zero height (unbounded constraints) | Replaced with `SingleChildScrollView` wrapping a `Column` |
| Artifacts screen empty folders | Backend `/business-profiles/:id/projects/all` endpoint did not exist | Added it in `backend/src/routes/business.ts` (see file below) |
| BRAND TONE label said "MAX 2" despite many edits | OneDrive sync delayed Edit tool changes from reaching the local file at the time of commit; multiple rebuilds of the ZIP were needed | Re-applied via direct .NET file write to bypass OneDrive's caching layer |

## Repo state — what is safe to merge

The **17 files** in the final `tamiva-android-fix-bundle.zip` are the canonical state. They mirror what has been built and tested.

### Final ZIP contents (17 files)

```
.github/workflows/build-aab.yml              race-handling retry, SDK setup, tag racing
.github/workflows/build-apk.yml              same
.github/scripts/next-version.sh              computes next vN.M.K tag
flutter_app/android/app/build.gradle.kts     CI-driven versionCode, rootProject.file() for keystore, minSdk 21, no isShrinkResources
flutter_app/android/settings.gradle.kts      AGP 8.9.1
flutter_app/android/gradle/wrapper/gradle-wrapper.properties  Gradle 8.11.1
flutter_app/lib/data/palette_styles.dart     byKey accepts displayName fallback
flutter_app/lib/data/font_pairs.dart         byKey accepts displayName fallback
flutter_app/lib/widgets/multi_select_sheet.dart  autoDismissOnSelect, onSelectionChanged for stepper UX
flutter_app/lib/services/api_client.dart     defensive response shape validation, _userFromAuthBody soft casts
flutter_app/lib/screens/welcome_screen.dart  clean — no diag, has "Account already exists" dialog routing
flutter_app/lib/screens/business_info_screen.dart  stepper UX (industry → tone → typography → palette), validation, "BRAND TONE (Pick one)" label
flutter_app/lib/screens/brand_assets_screen.dart  brand kit landing screen
flutter_app/lib/screens/artifacts_screen.dart  artifacts grid (uses /projects/all endpoint)
flutter_app/pubspec.yaml                     untouched — version comes from CLI flags
backend/src/prompts/index.ts                 PALETTE_HEX + FONT_CATEGORY_DESC for all 21 entries each
backend/src/routes/business.ts               new GET /business-profiles/:id/projects/all endpoint
```

## Things that could regress in a new chat session

| Risk | Symptom | Where to look |
|---|---|---|
| BRAND TONE label reverts to "MAX 2" | OneDrive sync delay | Force-write via PowerShell `[System.IO.File]::WriteAllText` — bypasses OneDrive cache |
| Sign-up dialog stops firing | Matcher regression or backend response change | Check `_looksLikeAlreadyRegistered()` in welcome_screen.dart — should match: "already registered" / "already has a studio" / "already exists" / "malformed auth response" / "userid missing" |
| Black screen on "About your business" | Form body reverted to `ListView` inside unbounded constraints | `business_info_screen.dart`'s `_buildForm` — `body:` argument should be `Form > SingleChildScrollView > Column`, not `ListView` |
| Build fails with "Removing unused resources..." | `isShrinkResources` line accidentally re-added to `app/build.gradle.kts` | Search the file for `isShrinkResources` and delete the line entirely |
| Tag race in CI | "vN.M.K already exists" in workflow logs | Check `Push Version Tag` step in both workflows — should have the retry loop (up to 5 attempts) |
| Artifacts screen empty | `/business-profiles/:id/projects/all` endpoint missing | Verify it is in `backend/src/routes/business.ts` and verify the Flutter client is calling that exact URL |

## What NOT to add without explicit user request

- New features beyond the existing flow scope (logo / carousel / video generation, payment, etc.) — these need backend work, frontend polish, and Play Store review prep.
- Major UI overhauls.
- New dependencies — they trigger Flutter Gradle plugin compatibility dance.
- Hardcoded `versionCode` / `versionName` in `app/build.gradle.kts` — they will collide with Play Console.
- `debugPrint` / `developer.log` / `print()` in production paths.

## Open items / known issues

1. **Backend `/auth/signup` has a 200-with-malformed-body bug.** The matcher works around it (catches "Malformed auth response" + "userId missing" and shows the dialog). But the root cause is on the backend — likely an idempotency cache issue or a race in `findUserByEmail` + `prisma.user.create`. Not investigated yet.

2. **Artifacts endpoint was added but may not be in HEAD yet.** When the user last tried `git add backend/src/routes/business.ts`, git said the file already matched HEAD. Worth verifying at https://github.com/tamiva-ai/tamiva-ai/blob/main/backend/src/routes/business.ts — search for `projects/all`. If absent, re-stage and commit.

3. **OneDrive sync issue is unfixed at the OS level.** Files extracted to `C:\Users\tmrut\OneDrive\Documents\GitHub\tamiva-ai\` can take a few minutes to be reflected by `git status`. Use `[System.IO.File]::WriteAllText` if a `git checkout HEAD -- <file>` does not take effect.

4. **Workflow race-handling retries up to 5 times.** If both AAB + APK workflows are hitting the tag simultaneously 5 times in a row, the build is overwhelmed — investigate CI load.

## Files in the next ZIP the user should pull

1. Download `tamiva-android-fix-bundle.zip` from the Cowork session's outputs folder.
2. Unzip into the repo root (`C:\Users\tmrut\OneDrive\Documents\GitHub\tamiva-ai`).
3. `git add <files>`, `git commit`, `git push origin main`.
4. Workflows auto-run on push; download the fresh APK from Actions artifacts.

## Recommended next steps (when user starts a new chat)

The next chat should:

1. **Verify the build still works** by re-running the APK workflow and installing the fresh APK on the user's device.
2. **Test all the flows** listed in "What's working" above.
3. **Only then** consider new features or fixes.
