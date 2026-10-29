import { NextResponse } from "next/server";
import { loadRegistry } from "@/lib/projects";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const registry = await loadRegistry();
    return NextResponse.json({ ok: true, projects: registry.projects });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
