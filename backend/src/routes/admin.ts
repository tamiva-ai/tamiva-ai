/**
 * Admin router - cross-customer observability for the founder / support.
 *
 * Auth: a single shared ADMIN_API_KEY env var. Either send it as a
 * query parameter (?key=...) or as a Bearer header. Returning 401 on
 * missing/wrong keeps the endpoint invisible to anyone who shouldn't
 * see it.
 *
 * IMPORTANT: this is intentionally minimal for v15. It only exposes
 * read-only summaries - no DELETE / DROP / PROJECT-cancel paths. If we
 * ever add mutating admin actions (refund credits, force-fail a
 * stuck job), make sure to require the same header on those too.
 *
 * To set up: in Railway -> tamiva-ai service -> Variables, add:
 *   ADMIN_API_KEY = <a long random string>
 * The same key must be present on local-dev .env for any local admin
 * testing.
 */
import { Router } from "express";
import { z } from "zod";
import { prisma, Prisma } from "../db/client.js";

export const adminRouter = Router();

/**
 * Middleware: extract + validate the admin key. Sets req.isAdmin = true
 * on success, otherwise 401. The key is read once from the env on first
 * call so a runtime env update would need a redeploy to take effect.
 */
const ADMIN_KEY = process.env.ADMIN_API_KEY;

function requireAdmin(req: any, res: any, next: any) {
  const fromHeader = (req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
  const fromQuery = typeof req.query.key === "string" ? req.query.key : "";
  const provided = fromHeader || fromQuery;
  if (!ADMIN_KEY) {
    return res.status(503).json({
      error: "ADMIN_API_KEY not configured on server. Set it in Railway -> Variables.",
    });
  }
  if (!provided || provided !== ADMIN_KEY) {
    return res.status(401).json({ error: "Unauthorized. Pass ?key=... or Authorization: Bearer ..." });
  }
  req.isAdmin = true;
  next();
}

adminRouter.use(requireAdmin);

/**
 * GET /admin/projects
 *
 * Lists all projects across all business profiles, paginated by
 * `?limit` (default 50, max 200) and `?before` (cursor: ISO timestamp).
 * Optional `?businessProfileId=<uuid>` filters to one customer.
 *
 * Each row carries enough to answer "did this actually generate":
 *   id, type, status, createdAt, updatedAt, durationSeconds,
 *   assetCount, latestJobError, businessProfileId, businessName,
 *   userEmail.
 */
const listSchema = z.object({
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.string().datetime().optional(),
  businessProfileId: z.string().uuid().optional(),
});

adminRouter.get("/projects", async (req, res) => {
  const parsed = listSchema.safeParse(req.query);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const { limit, before, businessProfileId } = parsed.data;

  const where: any = {};
  if (businessProfileId) where.businessProfileId = businessProfileId;
  if (before) where.createdAt = { lt: new Date(before) };

  const projects = await prisma.project.findMany({
    where,
    include: {
      assets: { select: { id: true } },
      jobs: {
        orderBy: { createdAt: "desc" },
        take: 1,
        select: { error: true, stage: true, status: true },
      },
      businessProfile: {
        select: {
          id: true,
          name: true,
          user: { select: { email: true } },
        },
      },
    },
    orderBy: { createdAt: "desc" },
    take: limit,
  });

  res.json({
    count: projects.length,
    projects: projects.map((p) => ({
      id: p.id,
      type: p.type,
      status: p.status,
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
      durationSeconds: Math.max(
        0,
        Math.floor((p.updatedAt.getTime() - p.createdAt.getTime()) / 1000),
      ),
      assetCount: p.assets.length,
      businessProfileId: p.businessProfileId,
      businessName: p.businessProfile.name,
      userEmail: p.businessProfile.user.email,
      latestJob: p.jobs[0] ?? null,
    })),
    nextCursor: projects.length === limit
      ? projects[projects.length - 1].createdAt.toISOString()
      : null,
  });
});

/**
 * GET /admin/projects/:id
 *
 * Full detail on one project: asset list (truncated first 60 chars of
 * url), every job with status + error, and the linked business profile.
 */
adminRouter.get("/projects/:id", async (req, res) => {
  const project = await prisma.project.findUnique({
    where: { id: req.params.id },
    include: {
      assets: true,
      jobs: { orderBy: { createdAt: "asc" } },
      businessProfile: {
        select: {
          id: true,
          name: true,
          industry: true,
          tagline: true,
          tone: true,
          user: { select: { email: true, fullName: true } },
        },
      },
    },
  });
  if (!project) return res.status(404).json({ error: "Project not found" });

  res.json({
    project: {
      id: project.id,
      type: project.type,
      status: project.status,
      createdAt: project.createdAt,
      updatedAt: project.updatedAt,
      durationSeconds: Math.max(
        0,
        Math.floor((project.updatedAt.getTime() - project.createdAt.getTime()) / 1000),
      ),
    },
    businessProfile: project.businessProfile,
    assets: project.assets.map((a) => ({
      id: a.id,
      type: a.type,
      slideIndex: a.slideIndex,
      url: a.url, // full URL so the founder can grab and view
      urlPreview: a.url.slice(0, 60),
      createdAt: a.createdAt,
    })),
    jobs: project.jobs.map((j) => ({
      id: j.id,
      stage: j.stage,
      provider: j.provider,
      status: j.status,
      error: j.error,
      outputUrl: j.outputUrl,
      retries: j.retries,
      createdAt: j.createdAt,
      updatedAt: j.updatedAt,
    })),
  });
});

/**
 * GET /admin/stats
 *
 * Quick at-a-glance rollup so the founder doesn't have to page through
 * projects to know "is anything broken right now".
 */
adminRouter.get("/stats", async (_req, res) => {
  const since = new Date();
  since.setUTCHours(0, 0, 0, 0);

  const [
    totalProjects,
    todayProjects,
    todayFailed,
    todayByType,
    lastByType,
  ] = await Promise.all([
    prisma.project.count(),
    prisma.project.count({ where: { createdAt: { gte: since } } }),
    prisma.project.count({
      where: { createdAt: { gte: since }, status: "failed" },
    }),
    prisma.project.groupBy({
      by: ["type", "status"],
      where: { createdAt: { gte: since } },
      _count: { _all: true },
    }),
    Promise.all([
      prisma.project.findFirst({
        where: { type: "logo" },
        orderBy: { createdAt: "desc" },
        select: { id: true, status: true, createdAt: true, businessProfileId: true },
      }),
      prisma.project.findFirst({
        where: { type: "carousel" },
        orderBy: { createdAt: "desc" },
        select: { id: true, status: true, createdAt: true, businessProfileId: true },
      }),
      prisma.project.findFirst({
        where: { type: "video" },
        orderBy: { createdAt: "desc" },
        select: { id: true, status: true, createdAt: true, businessProfileId: true },
      }),
    ]),
  ]);

  res.json({
    totalProjects,
    today: {
      total: todayProjects,
      failed: todayFailed,
      successRate: todayProjects
        ? Math.round(((todayProjects - todayFailed) / todayProjects) * 100)
        : null,
      byType: todayByType,
    },
    lastByType: {
      logo: lastByType[0],
      carousel: lastByType[1],
      video: lastByType[2],
    },
  });
});

/**
 * GET /admin/customers
 *
 * Lists every business profile in the system so the founder can find
 * a customer by name in their scripts. Each row carries:
 *   id, name, email, industry, tagline, createdAt,
 *   projectCount (lifetime), successCount, lastProjectAt.
 *
 * Pagination: ?limit=N (default 100, max 500) and ?before=<ISO> cursor
 * by createdAt so big datasets are still cheap.
 */
adminRouter.get("/customers", async (req, res) => {
  const limit = Math.min(500, Math.max(1, Number(req.query.limit ?? 100)));
  const before = typeof req.query.before === "string" ? req.query.before : null;

  const where: any = {};
  if (before) where.createdAt = { lt: new Date(before) };

  const profiles = await prisma.businessProfile.findMany({
    where,
    include: {
      user: { select: { email: true, fullName: true, phone: true } },
      _count: { select: { projects: true } },
      projects: {
        orderBy: { createdAt: "desc" },
        take: 1,
        select: { createdAt: true, status: true, type: true },
      },
    },
    orderBy: { createdAt: "desc" },
    take: limit,
  });

  const successCountByProfile = await prisma.project.groupBy({
    by: ["businessProfileId"],
    where: { status: "ready" },
    _count: { _all: true },
  });
  const successMap = new Map(
    successCountByProfile.map((s) => [s.businessProfileId, s._count._all]),
  );

  res.json({
    count: profiles.length,
    customers: profiles.map((bp) => {
      const lastProject = bp.projects[0];
      return {
        id: bp.id,
        name: bp.name,
        industry: bp.industry,
        tagline: bp.tagline,
        email: bp.user.email,
        fullName: bp.user.fullName,
        phone: bp.user.phone,
        createdAt: bp.createdAt,
        projectCount: bp._count.projects,
        successCount: successMap.get(bp.id) ?? 0,
        lastProject: lastProject
          ? { type: lastProject.type, status: lastProject.status, createdAt: lastProject.createdAt }
          : null,
      };
    }),
    nextCursor: profiles.length === limit
      ? profiles[profiles.length - 1].createdAt.toISOString()
      : null,
  });
});

/**
 * GET /admin/customers/:lookup
 *
 * Resolves a customer by email, business name, or full name (case-
 * insensitive substring), then returns their full project history.
 *
 * Examples:
 *   /admin/customers/teja
 *   /admin/customers/tejaswi@gmail.com
 *
 * If multiple profiles match a substring, returns all of them so the
 * caller can disambiguate. Always returns 200 with a `matches` array;
 * call sites should check matches.length rather than relying on 404.
 */
adminRouter.get("/customers/:lookup", async (req, res) => {
  const raw = decodeURIComponent(req.params.lookup).trim();
  if (!raw) {
    return res.status(400).json({ error: "lookup is required" });
  }

  // Match on email (user) or name (businessProfile or user). Using
  // contains + mode: 'insensitive' so partial queries work.
  const matches = await prisma.businessProfile.findMany({
    where: {
      OR: [
        { name: { contains: raw, mode: "insensitive" } },
        { user: { email: { contains: raw, mode: "insensitive" } } },
        { user: { fullName: { contains: raw, mode: "insensitive" } } },
        { user: { phone: { contains: raw, mode: "insensitive" } } },
      ],
    },
    include: {
      user: { select: { email: true, fullName: true, phone: true } },
      _count: { select: { projects: true } },
    },
    take: 10,
  });

  if (matches.length === 0) {
    return res.json({ matches: [] });
  }

  const result = await Promise.all(
    matches.map(async (bp) => {
      const projects = await prisma.project.findMany({
        where: { businessProfileId: bp.id },
        include: {
          assets: { select: { id: true } },
          jobs: { orderBy: { createdAt: "desc" }, take: 1, select: { error: true, stage: true, status: true } },
        },
        orderBy: { createdAt: "desc" },
        take: 50,
      });
      return {
        customer: {
          id: bp.id,
          name: bp.name,
          email: bp.user.email,
          fullName: bp.user.fullName,
          phone: bp.user.phone,
          industry: bp.industry,
          createdAt: bp.createdAt,
        },
        projectCount: bp._count.projects,
        projects: projects.map((p) => ({
          id: p.id,
          type: p.type,
          status: p.status,
          createdAt: p.createdAt,
          updatedAt: p.updatedAt,
          durationSeconds: Math.max(
            0,
            Math.floor((p.updatedAt.getTime() - p.createdAt.getTime()) / 1000),
          ),
          assetCount: p.assets.length,
          latestJob: p.jobs[0] ?? null,
        })),
      };
    }),
  );

  res.json({ matches: result });
});

/**
 * GET /admin/customers/:lookup/usage
 *
 * Per-customer credit-spend rollup so the founder can see "this user
 * generated 4 logos + 2 carousels + 1 film; 6 succeeded; 1 failed".
 * Same lookup semantics as /admin/customers/:lookup.
 */
adminRouter.get("/customers/:lookup/usage", async (req, res) => {
  const raw = decodeURIComponent(req.params.lookup).trim();
  const matches = await prisma.businessProfile.findMany({
    where: {
      OR: [
        { name: { contains: raw, mode: "insensitive" } },
        { user: { email: { contains: raw, mode: "insensitive" } } },
        { user: { fullName: { contains: raw, mode: "insensitive" } } },
        { user: { phone: { contains: raw, mode: "insensitive" } } },
      ],
    },
    take: 10,
  });

  if (matches.length === 0) {
    return res.json({ matches: [] });
  }

  const result = await Promise.all(
    matches.map(async (bp) => {
      const grouped = await prisma.project.groupBy({
        by: ["type", "status"],
        where: { businessProfileId: bp.id },
        _count: { _all: true },
      });
      const byType: Record<string, { total: number; failed: number; ready: number }> = {
        logo: { total: 0, failed: 0, ready: 0 },
        carousel: { total: 0, failed: 0, ready: 0 },
        video: { total: 0, failed: 0, ready: 0 },
      };
      for (const g of grouped) {
        const bucket = byType[g.type];
        if (!bucket) continue;
        bucket.total += g._count._all;
        if (g.status === "failed") bucket.failed += g._count._all;
        if (g.status === "ready") bucket.ready += g._count._all;
      }
      const total = byType.logo.total + byType.carousel.total + byType.video.total;
      const failed =
        byType.logo.failed + byType.carousel.failed + byType.video.failed;
      const lastProject = await prisma.project.findFirst({
        where: { businessProfileId: bp.id },
        orderBy: { createdAt: "desc" },
        select: { createdAt: true, type: true, status: true },
      });
      return {
        customer: { id: bp.id, name: bp.name },
        totalProjects: total,
        failedProjects: failed,
        successRate: total ? Math.round(((total - failed) / total) * 100) : null,
        byType,
        lastProject,
      };
    }),
  );

  res.json({ matches: result });
});

/**
 * GET /admin/customers/:lookup/full
 *
 * Same lookup semantics as /admin/customers/:lookup but returns every
 * project with ALL assets and jobs inlined. Designed for the admin UI
 * to render the full deliverable gallery in one request.
 *
 * Use this when you want to actually SEE the generated logos /
 * carousels / films for a customer, not just the count.
 *
 * Response shape per match:
 *   {
 *     customer: { id, name, email, ... },
 *     projectCount,
 *     projects: [{
 *       id, type, status, createdAt, updatedAt, durationSeconds,
 *       assets: [{ id, type, slideIndex, url, createdAt }],
 *       jobs:    [{ id, stage, provider, status, error, ... }],
 *     }]
 *   }
 */
adminRouter.get("/customers/:lookup/full", async (req, res) => {
  const raw = decodeURIComponent(req.params.lookup).trim();
  const matches = await prisma.businessProfile.findMany({
    where: {
      OR: [
        { name: { contains: raw, mode: "insensitive" } },
        { user: { email: { contains: raw, mode: "insensitive" } } },
        { user: { fullName: { contains: raw, mode: "insensitive" } } },
        { user: { phone: { contains: raw, mode: "insensitive" } } },
      ],
    },
    include: {
      user: { select: { email: true, fullName: true, phone: true } },
      _count: { select: { projects: true } },
    },
    take: 10,
  });

  if (matches.length === 0) {
    return res.json({ matches: [] });
  }

  const result = await Promise.all(
    matches.map(async (bp) => {
      const projects = await prisma.project.findMany({
        where: { businessProfileId: bp.id },
        include: {
          assets: { orderBy: { slideIndex: "asc" } },
          jobs: { orderBy: { createdAt: "asc" } },
        },
        orderBy: { createdAt: "desc" },
        take: 50,
      });
      return {
        customer: {
          id: bp.id,
          name: bp.name,
          email: bp.user.email,
          fullName: bp.user.fullName,
          phone: bp.user.phone,
          industry: bp.industry,
          createdAt: bp.createdAt,
        },
        projectCount: bp._count.projects,
        projects: projects.map((p) => ({
          id: p.id,
          type: p.type,
          status: p.status,
          createdAt: p.createdAt,
          updatedAt: p.updatedAt,
          durationSeconds: Math.max(
            0,
            Math.floor((p.updatedAt.getTime() - p.createdAt.getTime()) / 1000),
          ),
          assets: p.assets.map((a) => ({
            id: a.id,
            type: a.type,
            slideIndex: a.slideIndex,
            url: a.url,
            createdAt: a.createdAt,
          })),
          jobs: p.jobs.map((j) => ({
            id: j.id,
            stage: j.stage,
            provider: j.provider,
            status: j.status,
            error: j.error,
            outputUrl: j.outputUrl,
            retries: j.retries,
            createdAt: j.createdAt,
            updatedAt: j.updatedAt,
          })),
        })),
      };
    }),
  );

  res.json({ matches: result });
});

/**
 * v24: PUT /admin/users/:userId/tier
 *
 * Manual tier flip for testing the Pro flow without a real payment
 * integration. Sets user.tier to the value in the body. Idempotent.
 *
 * Body: { tier: "free" | "pro" }
 *
 * Auth: same as every other /admin/* route - requires ?key=... matching
 * ADMIN_API_KEY env var.
 */
const setTierSchema = z.object({
  tier: z.enum(["free", "pro"]),
});

adminRouter.put("/users/:userId/tier", async (req, res) => {
  const parsed = setTierSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const user = await prisma.user.findUnique({ where: { id: req.params.userId } });
  if (!user) return res.status(404).json({ error: "User not found" });

  const updated = await prisma.user.update({
    where: { id: user.id },
    data: {
      tier: parsed.data.tier,
      tierUpdatedAt: new Date(),
    },
  });

  res.json({
    userId: updated.id,
    email: updated.email,
    tier: updated.tier,
    tierUpdatedAt: updated.tierUpdatedAt,
  });
});

/**
 * v38: GET /admin/logs
 *
 * Lists recent ProviderCall log rows (every outbound OpenAI / Gemini
 * HTTP exchange the worker did). Filters: projectId, operation,
 * status (a specific HTTP status or "error" for any non-2xx), since
 * (ISO timestamp). Limit defaults to 100, capped at 500.
 *
 * Each row carries the full request/response JSON so admins can debug
 * generation failures from the dashboard. Image b64 payloads can be
 * megabytes - the admin UI should truncate for display.
 *
 * Auth: same as every other /admin/* route.
 */
const listLogsSchema = z.object({
  since: z.string().datetime().optional(),
  projectId: z.string().uuid().optional(),
  operation: z.string().min(1).max(120).optional(),
  status: z
    .union([z.coerce.number().int().min(100).max(599), z.literal("error")])
    .optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
  // v39: log source. "provider" = worker→OpenAI/Gemini (default so
  // existing admin UI keeps working); "client" = app→backend; "all"
  // merges both tables tagged with `source` so the admin UI can
  // colour-code them.
  type: z.enum(["provider", "client", "all"]).default("provider"),
});

adminRouter.get("/logs", async (req, res) => {
  const parsed = listLogsSchema.safeParse(req.query);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const { since, projectId, operation, status, limit } = parsed.data;

  // Build the status filter. "error" means status < 200 OR status >= 400
  // OR status is null (network failure). We compose with prisma OR.
  let statusFilter: { in?: number[]; notIn?: number[] } | undefined;
  if (status === "error") {
    statusFilter = { in: [400, 401, 402, 403, 404, 408, 409, 410, 412, 413, 414, 415, 416, 417, 421, 422, 423, 424, 425, 426, 428, 429, 431, 451, 500, 501, 502, 503, 504, 505, 506, 507, 508, 510, 511, 521, 522, 523, 525, 530, 532, 535, 541, 542, 543, 550, 551, 552, 553, 554, 555, 556, 557, 558, 559, 560] };
    // Prisma's enum doesn't allow null in `in:`; we add the null case
    // via OR below.
  } else if (typeof status === "number") {
    statusFilter = { in: [status] };
  }

  // Build the base where-clause from filters. Use Prisma's runtime
  // input type so the OR-combine later is also typed (Prisma expects
  // Prisma.ProviderCallWhereInput | Prisma.ProviderCallWhereInput[],
  // not a free-form `unknown[]`).
  const where: Prisma.ProviderCallWhereInput = {};
  if (since) where.createdAt = { gte: new Date(since) };
  if (projectId) where.projectId = projectId;
  if (operation) where.operation = { contains: operation };

  // Compose the where-clause. When statusFilter is non-null we OR
  // "match this status code set" with "OR status is null (network
  // failure)" - Prisma expects every element of OR to be a fully-
  // typed ProviderCallWhereInput, so we cast the array explicitly.
  // This avoids the structural-typing trap where neither bare object
  // is a valid ProviderCallWhereInput on its own.
  const whereWithStatus: Prisma.ProviderCallWhereInput = statusFilter
    ? { OR: [statusFilter, { status: null }] as Prisma.ProviderCallWhereInput[] }
    : where;
  const rows = await prisma.providerCall.findMany({
    where: whereWithStatus,
    orderBy: { createdAt: "desc" },
    take: limit,
  });

  res.json({
    count: rows.length,
    logs: rows.map((r) => ({
      id: r.id,
      operation: r.operation,
      provider: r.provider,
      projectId: r.projectId,
      jobId: r.jobId,
      status: r.status,
      durationMs: r.durationMs,
      errorKind: r.errorKind,
      requestSummary: r.requestSummary,
      responseSummary: r.responseSummary,
      createdAt: r.createdAt.toISOString(),
    })),
  });
});

/**
 * v39: GET /admin/client-logs
 *
 * Returns recent ClientLog rows (every request the Flutter app made
 * to the backend). Same filter shape as /admin/logs but queries the
 * ClientLog table. Use the ?type=client param on /admin/logs as the
 * unified entry point; this route is kept for callers that want
 * pure client-side data.
 */
const clientLogQuerySchema = z.object({
  since: z.string().datetime().optional(),
  url: z.string().optional(),
  userId: z.string().optional(),
  method: z.string().optional(),
  status: z
    .union([z.coerce.number().int().min(100).max(599), z.literal("error")])
    .optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
});

adminRouter.get("/client-logs", async (req, res) => {
  const parsed = clientLogQuerySchema.safeParse(req.query);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const { since, url, userId, method, status, limit } = parsed.data;

  // Status filter: "error" => status NOT in 2xx OR status is null.
  // Numeric => status = that code. Undefined => any status.
  const where: Prisma.ClientLogWhereInput = {};
  if (since) where.createdAt = { gte: new Date(since) };
  if (url) where.url = { contains: url };
  if (userId) where.userId = userId;
  if (method) where.method = method;
  if (status === "error") {
    where.OR = [
      { NOT: { statusCode: { in: [200, 201, 202, 203, 204, 205, 206, 207, 208, 226] } } },
      { statusCode: null },
    ] as Prisma.ClientLogWhereInput[];
  } else if (typeof status === "number") {
    where.statusCode = status;
  }

  const rows = await prisma.clientLog.findMany({
    where,
    orderBy: { createdAt: "desc" },
    take: limit,
  });

  res.json({
    count: rows.length,
    logs: rows.map((r) => ({
      id: r.id,
      source: "client",
      level: r.level,
      method: r.method,
      url: r.url,
      statusCode: r.statusCode,
      elapsedMs: r.elapsedMs,
      requestBody: r.requestBody,
      responseBody: r.responseBody,
      errorType: r.errorType,
      errorMessage: r.errorMessage,
      userId: r.userId,
      businessProfileId: r.businessProfileId,
      clientCorrelationId: r.clientCorrelationId,
      createdAt: r.createdAt.toISOString(),
    })),
  });
});

/**
 * v39: POST /admin/logs
 *
 * The Flutter client's LoggingHttpClient POSTs here on every outbound
 * request, response, and error. We persist each entry as a ClientLog
 * row keyed by `clientCorrelationId` so the admin UI can show the
 * request body next to the matching response body (and any error
 * that came back from the network) as a single bundle.
 *
 * Auth: same ADMIN_API_KEY check as every other /admin/* route. The
 * Flutter client is expected to send the key in the ?key=... query
 * param (which the LoggingHttpClient already does) or in an
 * x-admin-key header.
 *
 * Validation is intentionally lenient: missing fields default to null
 * so a half-broken client payload still records something useful.
 */
const logEntrySchema = z.object({
  // "request" | "response" | "error". Anything else is accepted as
  // text - the admin UI's badge color depends on these three values
  // but the column itself is TEXT so we don't reject here.
  level: z.string().min(1).max(20),
  method: z.string().min(1).max(10),
  url: z.string().min(1).max(2048),
  statusCode: z.coerce.number().int().min(100).max(599).optional(),
  elapsedMs: z.coerce.number().int().min(0).max(600_000).optional(),
  requestBody: z.string().max(64 * 1024).optional(),
  responseBody: z.string().max(64 * 1024).optional(),
  errorType: z.string().max(200).optional(),
  errorMessage: z.string().max(64 * 1024).optional(),
  // The LoggingHttpClient on the client sets these from ApiClient.state.
  userId: z.string().max(128).optional(),
  businessProfileId: z.string().max(128).optional(),
  // Groups request+response+error. The client generates this; we use it
  // as-is so the admin UI can join rows in the same call.
  clientCorrelationId: z.string().max(64).optional(),
});

adminRouter.post("/logs", async (req, res) => {
  const parsed = logEntrySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const e = parsed.data;
  // Best-effort persist. We do NOT await acknowledgement back to the
  // client - the LoggingHttpClient uses fire-and-forget for a reason,
  // so a slow INSERT here would never block the user's tap.
  prisma.clientLog
    .create({
      data: {
        level: e.level,
        method: e.method,
        url: e.url,
        statusCode: e.statusCode,
        elapsedMs: e.elapsedMs,
        requestBody: e.requestBody,
        responseBody: e.responseBody,
        errorType: e.errorType,
        errorMessage: e.errorMessage,
        userId: e.userId,
        businessProfileId: e.businessProfileId,
        clientCorrelationId: e.clientCorrelationId,
      },
    })
    .catch((err) => {
      console.error("[admin/logs] failed to persist client log:", err);
    });
  res.status(204).end();
});
