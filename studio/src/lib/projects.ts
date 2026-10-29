// Server-only: reads projects.json (this repo's project registry) and
// resolves a project id to its asset root on disk. Never import this from a
// client component — only API routes should touch it.
import { promises as fs } from "node:fs";
import path from "node:path";
import type { Device } from "./types";

export type ProjectEntry = {
  id: string;
  name: string;
  // Path to the project's asset root (app-store-screenshots.json +
  // screenshots/), relative to this repo's own root.
  root: string;
  defaultDevice?: Device;
};

export type ProjectRegistry = { projects: ProjectEntry[] };

const REGISTRY_FILE = "projects.json";

let cached: ProjectRegistry | null = null;

export async function loadRegistry(): Promise<ProjectRegistry> {
  // Cheap in dev (file read on every request) but avoids re-parsing on every
  // asset request in a single process; the registry only changes when a
  // human edits projects.json, which restarts the dev server anyway.
  if (cached) return cached;
  const raw = await fs.readFile(path.join(process.cwd(), REGISTRY_FILE), "utf8");
  cached = JSON.parse(raw) as ProjectRegistry;
  return cached;
}

export async function resolveProjectRoot(projectId: string): Promise<string> {
  const registry = await loadRegistry();
  const entry = registry.projects.find((p) => p.id === projectId);
  if (!entry) {
    throw new Error(`Unknown project: ${projectId}`);
  }
  return path.resolve(process.cwd(), entry.root);
}
