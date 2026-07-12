import "dotenv/config";
import express from "express";
import cors from "cors";
import path from "node:path";
import { businessRouter } from "./routes/business.js";
import { projectsRouter } from "./routes/projects.js";
import { uploadsRouter } from "./routes/uploads.js";
import { authRouter } from "./routes/auth.js";
import { adminRouter } from "./routes/admin.js";

const app = express();
app.use(cors());
app.use(express.json({ limit: "10mb" }));
app.use("/uploads", express.static(path.join(process.cwd(), "uploads")));

// Serve admin dashboard. Open https://<host>/admin?key=YOUR_KEY in a
// browser. The HTML page reads the key from the URL, calls the
// /admin/* endpoints, and renders results.
const adminDir = path.join(process.cwd(), "public");
app.use("/admin", express.static(adminDir));
app.get(["/admin", "/admin/"], (_req, res) => {
  res.sendFile(path.join(adminDir, "admin.html"));
});

app.get("/health", (_req, res) => res.json({ ok: true }));

app.use("/business-profiles", businessRouter);
app.use("/projects", projectsRouter);
app.use("/uploads", uploadsRouter);
app.use("/auth", authRouter);
app.use("/admin", adminRouter);

// Catches errors thrown by route handlers/multer and returns JSON instead
// of Express's default HTML error page - makes debugging from the app
// actually possible instead of getting a wall of raw HTML.
app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error(err);
  res.status(500).json({ error: err.message ?? "Internal server error" });
});

const port = process.env.PORT ?? 4000;
app.listen(port, () => {
  console.log(`Tamiva backend listening on port ${port}`);
});
