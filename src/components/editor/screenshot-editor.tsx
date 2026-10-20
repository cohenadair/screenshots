"use client";
import * as React from "react";
import JSZip from "jszip";
import { toPng } from "html-to-image";
import { useRouter, useSearchParams } from "next/navigation";
import { Toaster, toast } from "sonner";
import { toAssetUrl } from "@/lib/assets";
import {
  EXPORT_SIZES,
  LAST_PROJECT_STORAGE_KEY,
  getExportSizes,
  hasTheme,
  resolveTheme,
  supportsLandscape,
} from "@/lib/constants";
import { detectPlatform, nid } from "@/lib/defaults";
import { isBuiltInElementId, isTextElementId, textElementKey } from "@/lib/elements";
import { preloadImages } from "@/lib/image-cache";
import { resolveScreenshot, writeLocalized } from "@/lib/locale";
import type { ProjectEntry } from "@/lib/projects";
import { useProject } from "@/lib/storage";
import type {
  BuiltInElementId,
  Device,
  ElementId,
  ElementTransform,
  Orientation,
  SelectedElement,
  Slide,
} from "@/lib/types";
import { Inspector } from "./inspector";
import { PreviewStage } from "./preview-stage";
import { Sidebar } from "./sidebar";
import { DeckCanvas, getCanvas } from "./slide-canvas";
import { Toolbar } from "./toolbar";

type ExportTarget = { device: Device; orientation: Orientation };

// Resolves which registered project is active from the `?project=` URL
// query param — the source of truth so the URL stays bookmarkable and two
// tabs can independently edit two projects. On a bare load (no query param),
// falls back to the last-used project from localStorage, then the first
// registered project, and normalizes the URL via router.replace.
function useActiveProject(): {
  projectId: string;
  projects: ProjectEntry[];
  setActiveProjectId: (id: string) => void;
} {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [projects, setProjects] = React.useState<ProjectEntry[]>([]);
  const projectId = searchParams.get("project") || "";

  React.useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const resp = await fetch("/api/projects", { cache: "no-store" });
        const json = (await resp.json()) as { ok: boolean; projects?: ProjectEntry[] };
        if (cancelled || !json.ok || !json.projects) return;
        setProjects(json.projects);
        if (!projectId) {
          const last = window.localStorage.getItem(LAST_PROJECT_STORAGE_KEY);
          const fallback =
            (last && json.projects.some((p) => p.id === last) ? last : null) ||
            json.projects[0]?.id;
          if (fallback) {
            const params = new URLSearchParams(window.location.search);
            params.set("project", fallback);
            router.replace(`?${params.toString()}`);
          }
        }
      } catch {
        // Registry unreachable — the loading screen stays up; nothing else to do.
      }
    })();
    return () => {
      cancelled = true;
    };
    // Re-fetch is unnecessary once projects are loaded; only the initial
    // bare-load bootstrap needs projectId as a guard.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const setActiveProjectId = React.useCallback(
    (id: string) => {
      window.localStorage.setItem(LAST_PROJECT_STORAGE_KEY, id);
      const params = new URLSearchParams(window.location.search);
      params.set("project", id);
      router.push(`?${params.toString()}`);
    },
    [router],
  );

  return { projectId, projects, setActiveProjectId };
}

export function ScreenshotEditor() {
  const { projectId, projects, setActiveProjectId } = useActiveProject();
  const { state, setState, hydrated, savedAt, saveError, reset, resetDevice, undo, redo } =
    useProject(projectId);
  const [activeSlideId, setActiveSlideId] = React.useState<string | null>(null);
  const [selectedElement, setSelectedElement] = React.useState<SelectedElement | null>(null);
  const [exporting, setExporting] = React.useState<string | null>(null);
  const [exportMode, setExportMode] = React.useState<"bundle" | "all" | null>(null);
  // Device/orientation rendered by the off-screen export container; null
  // means the one currently being edited.
  const [exportTarget, setExportTarget] = React.useState<ExportTarget | null>(null);
  const [ready, setReady] = React.useState(false);
  const [exportLocaleOverride, setExportLocaleOverride] = React.useState<string | null>(null);
  const [exportSlideIndex, setExportSlideIndex] = React.useState(0);
  const exportRef = React.useRef<HTMLDivElement | null>(null);

  // Clear screen/element selection when switching projects — stale ids from
  // the previous project's slide deck don't carry over.
  React.useEffect(() => {
    setActiveSlideId(null);
    setSelectedElement(null);
  }, [projectId]);

  const slidesFor = (device: Device, orientation: Orientation) =>
    (state.slidesByDevice[device] || []).filter(
      (s) => !s.orientationFilter || s.orientationFilter === orientation,
    );
  const currentSlides = slidesFor(state.device, state.orientation);
  const activeSlide =
    currentSlides.find((s) => s.id === activeSlideId) || currentSlides[0] || null;
  const theme = resolveTheme(state, state.tenants, state.tenant);

  React.useEffect(() => {
    if (selectedElement && selectedElement.slideId !== activeSlide?.id) {
      setSelectedElement(null);
    }
  }, [activeSlide?.id, selectedElement]);

  React.useEffect(() => {
    if (!hydrated) return;
    if (!activeSlide && currentSlides.length > 0) {
      setActiveSlideId(currentSlides[0].id);
    }
  }, [hydrated, currentSlides, activeSlide]);

  React.useEffect(() => {
    if (!supportsLandscape(state.device) && state.orientation !== "portrait") {
      setState((p) => ({ ...p, orientation: "portrait" }));
    }
  }, [state.device, state.orientation, setState]);

  React.useEffect(() => {
    if (hydrated && !state.theme && state.themeId && !hasTheme(state.themeId)) {
      toast.warning("Using fallback theme", {
        description: `Theme "${state.themeId}" is not defined in src/lib/constants.ts, and this project has no inline "theme".`,
        duration: 8000,
      });
    }
  }, [hydrated, state.theme, state.themeId]);

  const assetPaths = React.useMemo(() => {
    const paths = new Set<string>();
    // Bundled with the tool itself — always served statically, not per-project.
    paths.add("/mockup.png");
    if (state.appIcon) paths.add(toAssetUrl(projectId, state.appIcon));
    // Preload every locale × tenant variant so bulk export doesn't race image loads.
    const tenantIds = state.tenants && state.tenants.length > 0 ? state.tenants.map((t) => t.id) : [undefined];
    const allSlides: Slide[] = Object.values(state.slidesByDevice).flat();
    for (const s of allSlides) {
      for (const raw of [s.screenshot, s.screenshotSecondary]) {
        if (!raw || raw.startsWith("data:")) continue;
        for (const tenantId of tenantIds) {
          if (raw.includes("{locale}")) {
            for (const loc of state.locales) {
              paths.add(toAssetUrl(projectId, resolveScreenshot(raw, loc, tenantId)));
            }
          } else {
            paths.add(toAssetUrl(projectId, resolveScreenshot(raw, state.locale, tenantId)));
          }
        }
      }
    }
    return Array.from(paths).sort();
  }, [state.slidesByDevice, state.appIcon, state.locales, state.locale, state.tenants, projectId]);
  const assetSig = assetPaths.join("|");

  React.useEffect(() => {
    if (!hydrated) return;
    preloadImages(assetPaths).finally(() => setReady(true));
    // assetPaths is derived from assetSig; depending on the string keeps the
    // effect from re-firing when slidesByDevice churns without path changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hydrated, assetSig]);

  // Surface storage failures (quota exceeded etc.) so the user knows their work isn't safe.
  React.useEffect(() => {
    if (saveError) {
      toast.error("Couldn't load or save project file", {
        description: saveError,
        duration: 8000,
      });
    }
  }, [saveError]);

  // ---------- Mutations ----------

  const patchSlide = React.useCallback(
    (id: string, patch: Partial<Slide>) => {
      setState((prev) => ({
        ...prev,
        slidesByDevice: {
          ...prev.slidesByDevice,
          [prev.device]: (prev.slidesByDevice[prev.device] || []).map((s) =>
            s.id === id ? { ...s, ...patch } : s,
          ),
        },
      }));
    },
    [setState],
  );

  const reorderSlides = React.useCallback(
    (next: Slide[]) => {
      setState((prev) => ({
        ...prev,
        slidesByDevice: { ...prev.slidesByDevice, [prev.device]: next },
      }));
    },
    [setState],
  );

  const deleteSlide = React.useCallback(
    (id: string) => {
      const dev = state.device;
      const slides = state.slidesByDevice[dev] || [];
      const idx = slides.findIndex((s) => s.id === id);
      if (idx === -1) return;
      const snap = slides[idx];
      const fallback = slides[idx + 1] || slides[idx - 1] || null;

      setState((prev) => {
        const cur = prev.slidesByDevice[dev] || [];
        return {
          ...prev,
          slidesByDevice: { ...prev.slidesByDevice, [dev]: cur.filter((s) => s.id !== id) },
        };
      });
      setActiveSlideId((cur) => (cur === id ? fallback?.id || null : cur));

      toast("Screen deleted", {
        action: {
          label: "Undo",
          onClick: () => {
            setState((prev) => {
              const cur = prev.slidesByDevice[dev] || [];
              if (cur.some((s) => s.id === snap.id)) return prev;
              const restored = [...cur.slice(0, idx), snap, ...cur.slice(idx)];
              return {
                ...prev,
                slidesByDevice: { ...prev.slidesByDevice, [dev]: restored },
              };
            });
            setActiveSlideId(snap.id);
          },
        },
        duration: 6000,
      });
    },
    [setState, state.device, state.slidesByDevice],
  );

  const addSlide = React.useCallback(
    (slide: Slide) => {
      setState((prev) => ({
        ...prev,
        slidesByDevice: {
          ...prev.slidesByDevice,
          [prev.device]: [...(prev.slidesByDevice[prev.device] || []), slide],
        },
      }));
      setActiveSlideId(slide.id);
    },
    [setState],
  );

  const patchLocalized = React.useCallback(
    (slide: Slide, key: "label" | "headline", value: string) => {
      patchSlide(slide.id, {
        [key]: writeLocalized(slide[key], state.locale, value),
      } as Partial<Slide>);
    },
    [patchSlide, state.locale],
  );

  const patchElementTransform = React.useCallback(
    (slideId: string, elementId: ElementId, transform: ElementTransform) => {
      setState((prev) => ({
        ...prev,
        slidesByDevice: {
          ...prev.slidesByDevice,
          [prev.device]: (prev.slidesByDevice[prev.device] || []).map((slide) => {
            if (slide.id !== slideId) return slide;
            if (isTextElementId(elementId)) {
              const textId = textElementKey(elementId);
              return {
                ...slide,
                textElements: (slide.textElements || []).map((element) =>
                  element.id === textId ? { ...element, transform } : element,
                ),
              };
            }
            if (!isBuiltInElementId(elementId)) return slide;
            return {
              ...slide,
              transforms: {
                ...(slide.transforms || {}),
                [elementId]: transform,
              } as Partial<Record<BuiltInElementId, ElementTransform>>,
            };
          }),
        },
      }));
    },
    [setState],
  );

  const patchTextElementText = React.useCallback(
    (slideId: string, textId: string, value: string) => {
      setState((prev) => ({
        ...prev,
        slidesByDevice: {
          ...prev.slidesByDevice,
          [prev.device]: (prev.slidesByDevice[prev.device] || []).map((slide) =>
            slide.id === slideId
              ? {
                  ...slide,
                  textElements: (slide.textElements || []).map((element) =>
                    element.id === textId
                      ? { ...element, text: writeLocalized(element.text, prev.locale, value) }
                      : element,
                  ),
                }
              : slide,
          ),
        },
      }));
    },
    [setState],
  );

  const duplicateSlide = React.useCallback(
    (id: string) => {
      let newId: string | null = null;
      setState((prev) => {
        const slides = prev.slidesByDevice[prev.device] || [];
        const idx = slides.findIndex((s) => s.id === id);
        if (idx === -1) return prev;
        const src = slides[idx];
        newId = nid();
        const copy: Slide = {
          ...src,
          id: newId,
          label: { ...src.label },
          headline: { ...src.headline },
          transforms: src.transforms
            ? Object.fromEntries(
                Object.entries(src.transforms).map(([key, value]) => [key, { ...value }]),
              )
            : undefined,
          textElements: src.textElements?.map((element) => ({
            ...element,
            id: nid(),
            text: { ...element.text },
            transform: { ...element.transform },
          })),
        };
        const next = [...slides.slice(0, idx + 1), copy, ...slides.slice(idx + 1)];
        return {
          ...prev,
          slidesByDevice: { ...prev.slidesByDevice, [prev.device]: next },
        };
      });
      if (newId) setActiveSlideId(newId);
    },
    [setState],
  );

  // ---------- Keyboard shortcuts ----------

  React.useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const target = e.target as HTMLElement | null;
      const inEditable =
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          (target as HTMLElement).isContentEditable);
      if (exporting) return;

      if (e.key === "Escape") {
        setSelectedElement(null);
        if (target && "blur" in target && typeof target.blur === "function") target.blur();
        return;
      }

      // Let focused inputs and contenteditable text keep their native undo,
      // redo, selection, and deletion behavior.
      if (inEditable) return;

      if ((e.metaKey || e.ctrlKey) && (e.key === "z" || e.key === "Z")) {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
        return;
      }
      if ((e.metaKey || e.ctrlKey) && (e.key === "y" || e.key === "Y")) {
        e.preventDefault();
        redo();
        return;
      }
      if (!currentSlides.length) return;
      const idx = activeSlide ? currentSlides.findIndex((s) => s.id === activeSlide.id) : -1;
      if (e.key === "ArrowDown" || (e.key === "j" && !e.metaKey && !e.ctrlKey)) {
        e.preventDefault();
        const next = currentSlides[Math.min(currentSlides.length - 1, idx + 1)];
        if (next) setActiveSlideId(next.id);
      } else if (e.key === "ArrowUp" || (e.key === "k" && !e.metaKey && !e.ctrlKey)) {
        e.preventDefault();
        const next = currentSlides[Math.max(0, idx - 1)];
        if (next) setActiveSlideId(next.id);
      } else if ((e.key === "d" || e.key === "D") && (e.metaKey || e.ctrlKey)) {
        if (activeSlide) {
          e.preventDefault();
          duplicateSlide(activeSlide.id);
        }
      } else if ((e.key === "Backspace" || e.key === "Delete") && (e.metaKey || e.ctrlKey)) {
        if (activeSlide) {
          e.preventDefault();
          deleteSlide(activeSlide.id);
        }
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [activeSlide, currentSlides, duplicateSlide, deleteSlide, exporting, undo, redo]);

  // ---------- Export ----------

  // Wait two animation frames so React's render → browser layout/paint of the
  // off-screen container settles before html-to-image snapshots it. One frame
  // is occasionally not enough on slower machines.
  const waitForPaint = () =>
    new Promise<void>((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
    });

  function exportBundle() {
    const platform = detectPlatform(state.device);
    return runExport(
      "bundle",
      [{ device: state.device, orientation: state.orientation }],
      `${slugify(state.appName)}-${platform}-${state.device}-${stamp()}.zip`,
    );
  }

  function exportEverything() {
    const targets: ExportTarget[] = [];
    for (const device of Object.keys(EXPORT_SIZES) as Device[]) {
      const orientations: Orientation[] = supportsLandscape(device)
        ? ["portrait", "landscape"]
        : ["portrait"];
      for (const orientation of orientations) {
        if (slidesFor(device, orientation).length > 0) {
          targets.push({ device, orientation });
        }
      }
    }
    return runExport("all", targets, `${slugify(state.appName)}-all-${stamp()}.zip`);
  }

  async function runExport(mode: "bundle" | "all", targets: ExportTarget[], zipName: string) {
    const jobs = targets
      .map((target) => ({
        ...target,
        slides: slidesFor(target.device, target.orientation),
        sizes: getExportSizes(target.device, target.orientation),
      }))
      .filter((job) => job.slides.length > 0);
    if (!jobs.length) {
      toast.error("No screens to export");
      return;
    }
    if (jobs.every((job) => !job.sizes.length)) {
      toast.error("Nothing to export");
      return;
    }
    const locales = state.locales;
    await preloadImages(assetPaths, { retryFailed: true });
    await waitForPaint();

    let missingCount = 0;
    let reusedBackCount = 0;
    for (const job of jobs) {
      missingCount += job.slides.filter(
        (slide) => slideNeedsScreenshot(job.device, slide) && !slide.screenshot,
      ).length;
      reusedBackCount += job.slides.filter(
        (slide) =>
          job.device !== "feature-graphic" &&
          slide.layout === "two-devices" &&
          slide.screenshot &&
          !slide.screenshotSecondary,
      ).length;
    }
    if (missingCount > 0 || reusedBackCount > 0) {
      const details = [
        missingCount
          ? `${missingCount} screen${missingCount === 1 ? "" : "s"} will export with an empty device.`
          : null,
        reusedBackCount
          ? `${reusedBackCount} two-device screen${reusedBackCount === 1 ? "" : "s"} will reuse the primary screenshot in back.`
          : null,
      ].filter(Boolean);
      toast.warning("Export includes placeholder screenshots", {
        description: details.join(" "),
        duration: 7000,
      });
    }

    // Make sure custom fonts are loaded before snapshot so typography in PNG
    // matches what's on screen.
    if (typeof document !== "undefined" && document.fonts && document.fonts.ready) {
      try {
        await document.fonts.ready;
      } catch {
        /* ignore */
      }
    }

    const zip = new JSZip();
    const totalUnits = jobs.reduce(
      (sum, job) => sum + job.sizes.length * locales.length * job.slides.length,
      0,
    );
    let unit = 0;
    let okCount = 0;
    let failed = 0;
    const errors: string[] = [];
    setExportMode(mode);

    for (const job of jobs) {
      const { cW, cH } = getCanvas(job.device, job.orientation);
      const platform = detectPlatform(job.device);
      setExportTarget({ device: job.device, orientation: job.orientation });

      for (const locale of locales) {
        setExportLocaleOverride(locale);
        await waitForPaint();

        for (const size of job.sizes) {
          for (let i = 0; i < job.slides.length; i++) {
            const slide = job.slides[i];
            unit += 1;
            setExporting(`${unit}/${totalUnits}`);
            setExportSlideIndex(i);
            await waitForPaint();
            const el = exportRef.current;
            if (!el) {
              failed += 1;
              errors.push(`${job.device} ${locale} ${size.w}×${size.h} screen ${i + 1}: render target missing`);
              continue;
            }
            try {
              const dataUrl = await captureSlide(el, cW, cH, size.w, size.h);
              const base64 = dataUrl.split(",")[1] || "";
              const filename = `${String(i + 1).padStart(2, "0")}-${slide.layout}.png`;
              const path = `${platform}/${job.device}/${size.w}x${size.h}/${locale}/${filename}`;
              zip.file(path, base64, { base64: true });
              okCount += 1;
            } catch (e) {
              failed += 1;
              const msg = e instanceof Error ? e.message : String(e);
              errors.push(`${job.device} ${locale} ${size.w}×${size.h} screen ${i + 1}: ${msg}`);
              console.error("Export failed", { slideId: slide.id, device: job.device, locale, size }, e);
            }
          }
        }
      }
    }

    setExportTarget(null);
    setExportLocaleOverride(null);
    setExporting(null);
    setExportMode(null);

    if (okCount > 0) {
      try {
        const blob = await zip.generateAsync({ type: "blob" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = zipName;
        a.click();
        setTimeout(() => URL.revokeObjectURL(url), 5000);
      } catch (e) {
        toast.error("Couldn't bundle export");
        console.error(e);
        return;
      }
    }

    const sizeCount = jobs.reduce((sum, job) => sum + job.sizes.length, 0);
    const deviceSummary =
      mode === "all" ? `${jobs.length} device deck${jobs.length === 1 ? "" : "s"}, ` : "";
    const summary = `${deviceSummary}${locales.length} locale${locales.length === 1 ? "" : "s"} × ${sizeCount} size${sizeCount === 1 ? "" : "s"}`;
    if (failed === 0) {
      toast.success(`Exported ${okCount} PNGs (${summary})`);
    } else if (okCount === 0) {
      toast.error(`All ${failed} renders failed`, {
        description: errors.slice(0, 3).join("\n"),
      });
    } else {
      toast.error(`${failed} of ${totalUnits} renders failed`, {
        description: errors.slice(0, 3).join("\n"),
      });
    }
  }

  async function captureSlide(
    el: HTMLElement,
    sourceW: number,
    sourceH: number,
    exportW: number,
    exportH: number,
  ) {
    // html-to-image needs the node at (0,0). Let the library scale the source
    // canvas into the requested output dimensions; CSS transforms leave
    // transparent gutters when export aspect ratios differ by a few pixels.
    const prev = {
      left: el.style.left,
      top: el.style.top,
      position: el.style.position,
      transform: el.style.transform,
      transformOrigin: el.style.transformOrigin,
      zIndex: el.style.zIndex,
    };
    el.style.left = "0px";
    el.style.top = "0px";
    el.style.position = "absolute";
    el.style.transform = "none";
    el.style.transformOrigin = "top left";
    el.style.zIndex = "-1";
    try {
      // waitForPaint's two RAFs are not a guarantee that large images have
      // finished decoding — without this, toPng can snapshot before a big
      // screenshot has painted, producing a blank/black device frame. Race
      // against a timeout: img.decode() can hang indefinitely on some images
      // in Chromium, and el spans the whole multi-screen deck, so one stuck
      // decode must not block every remaining export.
      await Promise.all(
        Array.from(el.querySelectorAll("img")).map((img) =>
          Promise.race([
            img.decode().catch(() => undefined),
            new Promise((resolve) => setTimeout(resolve, 3000)),
          ]),
        ),
      );
      const toPngOptions = {
        width: sourceW,
        height: sourceH,
        canvasWidth: exportW,
        canvasHeight: exportH,
        pixelRatio: 1,
        cacheBust: false,
        backgroundColor: "#ffffff",
      };
      // html-to-image's own embedImages step skips waiting on <img> src that
      // are already data: URLs (see node_modules/html-to-image/lib/embed-
      // images.js embedImageNode) — which is exactly what every screenshot
      // is, since image-cache.ts pre-converts them to data URIs. That means
      // nothing waits for the library's internally cloned <img> to actually
      // finish loading before the SVG->canvas rasterization runs, and the
      // clone can snapshot blank. Rendering twice and keeping the second
      // result is the documented workaround for this class of bug.
      await toPng(el, toPngOptions);
      const dataUrl = await toPng(el, toPngOptions);
      return dataUrl;
    } finally {
      el.style.left = prev.left || "-99999px";
      el.style.top = prev.top || "0px";
      el.style.position = prev.position || "absolute";
      el.style.transform = prev.transform;
      el.style.transformOrigin = prev.transformOrigin;
      el.style.zIndex = prev.zIndex;
    }
  }

  // ---------- Render ----------

  if (!hydrated || !ready) {
    return (
      <div className="flex h-screen items-center justify-center">
        <div className="flex flex-col items-center gap-2 text-muted-foreground">
          <div className="h-6 w-6 animate-spin rounded-full border-2 border-current border-t-transparent" />
          <p className="text-sm">Loading editor…</p>
        </div>
      </div>
    );
  }

  const exportDevice = exportTarget?.device ?? state.device;
  const exportOrientation = exportTarget?.orientation ?? state.orientation;
  const exportSlides = slidesFor(exportDevice, exportOrientation);
  const { cW, cH } = getCanvas(exportDevice, exportOrientation);
  const busy = !!exporting;

  return (
    <div className="flex h-screen flex-col overflow-hidden bg-background">
      <Toaster position="top-right" richColors closeButton />
      <Toolbar
        appName={state.appName}
        setAppName={(v) => setState((p) => ({ ...p, appName: v }))}
        projects={projects}
        activeProjectId={projectId}
        setActiveProjectId={setActiveProjectId}
        connectedCanvas={state.connectedCanvas}
        setConnectedCanvas={(v) => setState((p) => ({ ...p, connectedCanvas: v }))}
        locale={state.locale}
        setLocale={(v) => setState((p) => ({ ...p, locale: v }))}
        locales={state.locales}
        tenants={state.tenants || []}
        tenant={state.tenant || ""}
        setTenant={(v) => setState((p) => ({ ...p, tenant: v }))}
        device={state.device}
        setDevice={(v) => setState((p) => ({ ...p, device: v }))}
        orientation={state.orientation}
        setOrientation={(v) => setState((p) => ({ ...p, orientation: v }))}
        onExport={exportBundle}
        onExportAll={exportEverything}
        onResetAll={() => {
          reset();
          setActiveSlideId(null);
          toast.success("Reset all devices to defaults");
        }}
        onResetDevice={() => {
          resetDevice(state.device);
          setActiveSlideId(null);
          toast.success(`Reset ${state.device} to defaults`);
        }}
        exporting={exporting}
        exportMode={exportMode}
        savedAt={savedAt}
        saveError={saveError}
        busy={busy}
      />

      <div className="flex flex-1 overflow-hidden md:flex-row flex-col">
        <aside className="md:w-72 w-full shrink-0 border-r bg-card md:max-h-none max-h-64 overflow-hidden">
          <Sidebar
            slides={currentSlides}
            activeId={activeSlide?.id || null}
            device={state.device}
            orientation={state.orientation}
            theme={theme}
            locale={state.locale}
            projectId={projectId}
            tenant={state.tenant}
            appName={state.appName}
            appIcon={state.appIcon}
            connectedCanvas={state.connectedCanvas}
            disabled={busy}
            onReorder={reorderSlides}
            onSelect={setActiveSlideId}
            onDelete={deleteSlide}
            onDuplicate={duplicateSlide}
            onAdd={addSlide}
          />
        </aside>

        <main className="flex flex-1 items-stretch overflow-hidden min-h-0">
          {activeSlide && currentSlides.length > 0 ? (
            <PreviewStage
              slides={currentSlides}
              activeSlideId={activeSlide.id}
              device={state.device}
              orientation={state.orientation}
              theme={theme}
              locale={state.locale}
              projectId={projectId}
              tenant={state.tenant}
              appName={state.appName}
              appIcon={state.appIcon}
              connectedCanvas={state.connectedCanvas}
              selectedElement={selectedElement}
              onActiveSlideChange={setActiveSlideId}
              onLabelChange={(slide, v) => patchLocalized(slide, "label", v)}
              onHeadlineChange={(slide, v) => patchLocalized(slide, "headline", v)}
              onTextElementTextChange={patchTextElementText}
              onElementChange={patchElementTransform}
              onSelectElement={setSelectedElement}
            />
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center gap-2 p-8 text-center text-sm text-muted-foreground">
              <p className="font-medium text-foreground">No screen selected</p>
              <p>Add a screen on the left to get started.</p>
            </div>
          )}
        </main>

        <aside className="md:w-80 w-full shrink-0 border-l bg-card md:max-h-none max-h-96 overflow-hidden">
          {activeSlide ? (
            <Inspector
              slide={activeSlide}
              device={state.device}
              orientation={state.orientation}
              locale={state.locale}
              projectId={projectId}
              tenant={state.tenant}
              selectedElementId={
                selectedElement?.slideId === activeSlide.id ? selectedElement.elementId : null
              }
              onChange={(patch) => patchSlide(activeSlide.id, patch)}
              onSelectElement={(elementId) =>
                setSelectedElement(
                  elementId ? { slideId: activeSlide.id, elementId } : null,
                )
              }
            />
          ) : (
            <div className="flex h-full flex-col items-center justify-center gap-2 p-6 text-center text-sm text-muted-foreground">
              <p className="font-medium text-foreground">Nothing to inspect</p>
              <p className="text-xs">Screen settings will appear here once you add or select one.</p>
            </div>
          )}
        </aside>
      </div>

      {/* Off-screen export container — full-resolution canvases for html-to-image. */}
      <div
        aria-hidden
        style={{
          position: "absolute",
          left: -99999,
          top: 0,
          pointerEvents: "none",
        }}
      >
        {exportSlides.length > 0 && (
          <div
            ref={exportRef}
            style={{
              width: cW,
              height: cH,
              overflow: "hidden",
              position: "absolute",
              left: -99999,
              top: 0,
            }}
          >
            <div
              style={{
                position: "absolute",
                left: -exportSlideIndex * cW,
                top: 0,
                width: cW * exportSlides.length,
                height: cH,
              }}
            >
              <DeckCanvas
                slides={exportSlides}
                device={exportDevice}
                orientation={exportOrientation}
                theme={theme}
                locale={exportLocaleOverride ?? state.locale}
                projectId={projectId}
                tenant={state.tenant}
                appName={state.appName}
                appIcon={state.appIcon}
                connectedCanvas={state.connectedCanvas}
                hideEmpty
              />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function slugify(s: string) {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/(^-|-$)/g, "") || "screenshots"
  );
}

function slideNeedsScreenshot(device: Device, slide: Slide) {
  if (device === "feature-graphic") return false;
  return slide.layout !== "no-device" && slide.layout !== "feature-graphic";
}

function stamp() {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
}
