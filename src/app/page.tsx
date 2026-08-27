import { Suspense } from "react";
import { ScreenshotEditor } from "@/components/editor/screenshot-editor";

export default function Page() {
  return (
    <Suspense
      fallback={
        <div className="flex h-screen items-center justify-center">
          <div className="flex flex-col items-center gap-2 text-muted-foreground">
            <div className="h-6 w-6 animate-spin rounded-full border-2 border-current border-t-transparent" />
            <p className="text-sm">Loading editor…</p>
          </div>
        </div>
      }
    >
      <ScreenshotEditor />
    </Suspense>
  );
}
