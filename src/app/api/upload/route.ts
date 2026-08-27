import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { NextResponse } from "next/server";
import { resolveProjectRoot } from "@/lib/projects";

export const dynamic = "force-dynamic";

const MIME_EXT: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
};

function parseDataUrl(dataUrl: string): { mime: string; bytes: Buffer } | null {
  const m = /^data:([^;]+);base64,(.+)$/.exec(dataUrl);
  if (!m) return null;
  const mime = m[1].toLowerCase();
  const bytes = Buffer.from(m[2], "base64");
  return { mime, bytes };
}

export async function POST(req: Request) {
  const projectId = new URL(req.url).searchParams.get("project");
  if (!projectId) {
    return NextResponse.json({ ok: false, error: "Missing project" }, { status: 400 });
  }

  let body: { dataUrl?: string };
  try {
    body = (await req.json()) as { dataUrl?: string };
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid JSON" }, { status: 400 });
  }
  if (!body?.dataUrl || typeof body.dataUrl !== "string") {
    return NextResponse.json({ ok: false, error: "Missing dataUrl" }, { status: 400 });
  }
  const parsed = parseDataUrl(body.dataUrl);
  if (!parsed) {
    return NextResponse.json({ ok: false, error: "Unsupported data URL" }, { status: 400 });
  }
  const ext = MIME_EXT[parsed.mime];
  if (!ext) {
    return NextResponse.json(
      { ok: false, error: `Unsupported mime: ${parsed.mime}` },
      { status: 400 },
    );
  }
  if (parsed.bytes.byteLength > 8 * 1024 * 1024) {
    return NextResponse.json({ ok: false, error: "Image too large (>8MB)" }, { status: 413 });
  }

  const hash = createHash("sha1").update(parsed.bytes).digest("hex").slice(0, 16);
  const filename = `${hash}.${ext}`;

  try {
    const root = await resolveProjectRoot(projectId);
    const absDir = path.join(root, "screenshots", "uploaded");
    const absFile = path.join(absDir, filename);
    await fs.mkdir(absDir, { recursive: true });
    try {
      await fs.access(absFile);
    } catch {
      await fs.writeFile(absFile, parsed.bytes);
    }
    return NextResponse.json({
      ok: true,
      path: `/api/asset/${projectId}/screenshots/uploaded/${filename}`,
    });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
