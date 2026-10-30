import { promises as fs } from "node:fs";
import path from "node:path";
import { NextResponse } from "next/server";
import { resolveProjectRoot } from "@/lib/projects";
import { toRelativeAssetPath } from "@/lib/assets";

export const dynamic = "force-dynamic";

const PROJECT_FILE = "app-store-screenshots.json";

// The editor's current selection (which device/locale/etc. is showing) is UI
// state, not deck content. It's kept in one file local to this repo, keyed by
// project id, so switching devices doesn't dirty each project's own repo.
const SELECTION_FILE = path.join(process.cwd(), "selection.json");
const SELECTION_KEYS = ["device", "orientation", "locale", "tenant"] as const;

type Selection = Partial<Record<(typeof SELECTION_KEYS)[number], unknown>>;

async function filePath(projectId: string) {
  return path.join(await resolveProjectRoot(projectId), PROJECT_FILE);
}

async function readSelections(): Promise<Record<string, Selection>> {
  try {
    return JSON.parse(await fs.readFile(SELECTION_FILE, "utf8"));
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw e;
  }
}

// Splits the selection out of a posted state. The deck keeps whatever
// selection its file already has (the starting point for a fresh clone), so
// changing the selection never rewrites the project file.
function splitSelection(
  state: Record<string, unknown>,
  existing: Record<string, unknown>,
) {
  const deck = { ...state };
  const selection: Selection = {};
  for (const key of SELECTION_KEYS) {
    if (key in deck) {
      selection[key] = deck[key];
    }
    if (key in existing) {
      deck[key] = existing[key];
    } else {
      delete deck[key];
    }
  }
  return { deck, selection };
}

async function readProjectFile(projectId: string): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await fs.readFile(await filePath(projectId), "utf8"));
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return {};
    throw e;
  }
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
    // A project file's own selection is only a fallback for projects with
    // nothing in the shared file yet.
    const selection = (await readSelections())[projectId] ?? {};
    return NextResponse.json({ ok: true, state: { ...parsed, ...selection } });
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
    const normalized = stripAssetUrls(projectId, body) as Record<string, unknown>;
    const { deck, selection } = splitSelection(
      normalized,
      await readProjectFile(projectId),
    );
    const selections = await readSelections();
    selections[projectId] = selection;
    await fs.writeFile(SELECTION_FILE, JSON.stringify(selections, null, 2) + "\n", "utf8");
    const pretty = JSON.stringify(deck, null, 2) + "\n";
    await fs.writeFile(await filePath(projectId), pretty, "utf8");
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
