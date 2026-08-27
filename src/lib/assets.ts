// Turns a path stored in a project's app-store-screenshots.json (relative to
// that project's own asset root, e.g. "screenshots/apple/iphone/en/01.png")
// into a fetchable URL served by the dynamic /api/asset route. Project
// assets live outside this tool's own repo, so they can't be served from
// Next's static public/ folder — see src/app/api/asset/[...path]/route.ts.
export function toAssetUrl(projectId: string, relativePath: string | undefined): string {
  if (!relativePath) return "";
  if (relativePath.startsWith("data:")) return relativePath;
  // Already a fully-resolved URL (e.g. a fresh /api/upload response echoed
  // straight back into an onChange handler before the next save/reload).
  if (relativePath.startsWith("/api/asset/") || relativePath.startsWith("http")) {
    return relativePath;
  }
  return `/api/asset/${projectId}/${relativePath}`;
}

// Inverse of toAssetUrl: strips a project's /api/asset/<projectId>/ prefix
// so app-store-screenshots.json always stores project-relative paths, even
// if a value passed through the client already carrying a resolved URL.
export function toRelativeAssetPath(projectId: string, value: string): string {
  const prefix = `/api/asset/${projectId}/`;
  return value.startsWith(prefix) ? value.slice(prefix.length) : value;
}
