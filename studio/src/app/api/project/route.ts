import { promises as fs } from "node:fs";
import path from "node:path";
import { NextResponse } from "next/server";
import { resolveProjectRoot } from "@/lib/projects";
import { toRelativeAssetPath } from "@/lib/assets";

export const dynamic = "force-dynamic";

const PROJECT_FILE = "app-store-screenshots.json";

async function filePath(projectId: string) {
  return path.join(await resolveProjectRoot(projectId), PROJECT_FILE);
}

function stripAssetUrls(projectId: string, value: unknown): unknown {
  if (typeof value === "string") return toRelativeAssetPath(projectId, value);
  if (Array.isArray(value)) return value.map((v) => stripAssetUrls(projectId, v));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, stripAssetUrls(projectId, v)]),
    );
  }
  return value;
}

export async function GET(req: Request) {
  const projectId = new URL(req.url).searchParams.get("project");
  if (!projectId) {
    return NextResponse.json({ ok: false, error: "Missing project" }, { status: 400 });
  }
  try {
    const raw = await fs.readFile(await filePath(projectId), "utf8");
    const parsed = JSON.parse(raw);
    return NextResponse.json({ ok: true, state: parsed });
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return NextResponse.json({ ok: true, state: null });
    }
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}

export async function POST(req: Request) {
  const projectId = new URL(req.url).searchParams.get("project");
  if (!projectId) {
    return NextResponse.json({ ok: false, error: "Missing project" }, { status: 400 });
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid JSON" }, { status: 400 });
  }
  try {
    // Normalize any already-resolved /api/asset/<projectId>/... URLs (e.g.
    // fresh upload responses echoed straight into state) back to
    // project-relative paths, so the persisted JSON never mixes shapes.
    const normalized = stripAssetUrls(projectId, body);
    const pretty = JSON.stringify(normalized, null, 2) + "\n";
    await fs.writeFile(await filePath(projectId), pretty, "utf8");
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
