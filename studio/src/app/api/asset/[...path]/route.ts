import { promises as fs } from "node:fs";
import path from "node:path";
import { NextResponse } from "next/server";
import { resolveProjectRoot } from "@/lib/projects";

export const dynamic = "force-dynamic";

// Serves per-project screenshots/icons/uploads that live outside this repo
// (in each Flutter project's own asset root). Next's static public/ folder
// can only serve files inside this repo, so project assets are streamed
// through this route instead. Route shape: /api/asset/<projectId>/<...path>.
const MIME_BY_EXT: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
};

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ path: string[] }> },
) {
  const segments = (await params).path;
  const [projectId, ...rest] = segments;
  if (!projectId || rest.length === 0) {
    return new NextResponse("Not found", { status: 404 });
  }

  let root: string;
  try {
    root = await resolveProjectRoot(projectId);
  } catch {
    return new NextResponse("Unknown project", { status: 404 });
  }

  const resolved = path.resolve(root, ...rest);
  // Block path traversal out of the project's asset root (e.g. `..%2F..`).
  if (!resolved.startsWith(root + path.sep) && resolved !== root) {
    return new NextResponse("Forbidden", { status: 403 });
  }

  const mime = MIME_BY_EXT[path.extname(resolved).toLowerCase()];
  if (!mime) {
    return new NextResponse("Unsupported file type", { status: 415 });
  }

  try {
    const bytes = await fs.readFile(resolved);
    return new NextResponse(new Uint8Array(bytes), {
      headers: { "content-type": mime, "cache-control": "no-store" },
    });
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return new NextResponse("Not found", { status: 404 });
    }
    return new NextResponse("Internal error", { status: 500 });
  }
}
