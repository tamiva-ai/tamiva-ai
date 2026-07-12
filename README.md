# Tamiva app — MVP scaffold

This is the logo + carousel MVP slice from the architecture plan: a working
backend (built and type-checked in this environment) and a Flutter client
(written but not runnable here — this sandbox has no Flutter SDK or
pub.dev access). Video generation is stubbed in the queue/provider layer
but not yet wired into a route — that's the natural next slice.

## What's real vs. stubbed

**Actually working (installed, type-checked, and compiled in this session):**
- Express + TypeScript API: business profiles, ambassador photo upload, logo project creation, carousel project creation, project status polling
- Prisma schema matching the full data model
- BullMQ queue + worker wiring for async logo/carousel/video jobs
- OpenAI GPT Image provider client
- Gemini video provider client (Veo 3.1 / Omni Flash routing)

**Stubbed / needs real wiring before production:**
- Carousel slide copy (currently a placeholder loop — swap in a real Claude API call structured hook → problem → solution → proof → CTA)
- Photo storage (local disk right now — swap for R2 presigned uploads)
- Auth (a hardcoded dev user id in the Flutter app — needs real auth)
- Video generation isn't yet exposed as a `/projects/video` route — the provider client and queue job exist, but the multi-stage orchestration (hero image → storyboard → per-shot prompts → render → composite) still needs to be built as the next milestone
- Compositing (text/logo overlay via FFmpeg/Sharp/Puppeteer) — not yet implemented; assets currently ship as raw AI output

## Running the backend

```bash
cd backend
npm install
cp .env.example .env   # fill in OPENAI_API_KEY, GEMINI_API_KEY, DATABASE_URL, REDIS_URL

# needs Postgres + Redis running locally, e.g.:
# docker run -d -p 5432:5432 -e POSTGRES_USER=tamiva -e POSTGRES_PASSWORD=tamiva -e POSTGRES_DB=tamiva postgres:16
# docker run -d -p 6379:6379 redis:7

npx prisma migrate dev --name init
npm run dev       # starts the API on :4000
npm run worker    # in a second terminal — processes the generation queue
```

## Running the Flutter app

This needs the Flutter SDK on your machine (not available in this sandbox):

```bash
cd flutter_app
flutter pub get
flutter run   # point an Android emulator or device at it
```

Update `lib/main.dart`'s `baseUrl` to your backend's address before running
on a physical device (10.0.2.2 only works for the Android emulator talking
to your host machine).

## Suggested next steps, in order

1. Get the logo flow working end-to-end against real API keys — cheapest way to validate the whole plumbing
2. Wire up real carousel copy generation via Claude API
3. Build the video route + multi-stage orchestration
4. Build the compositing service (this is the piece that replaces your manual Filmora step)
5. Swap local disk storage for R2, add real auth, add the credits ledger
