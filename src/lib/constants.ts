import type { Device, Orientation, SlideLayout, Tenant, Theme, ThemeId } from "./types";

// ---------- Canvas dimensions (design at largest required resolution) ----------
export const CANVAS: Record<Device, { w: number; h: number; wL?: number; hL?: number }> = {
  iphone:        { w: 1320, h: 2868 },
  ipad:          { w: 2064, h: 2752 },
  android:       { w: 1080, h: 1920 },
  "android-7":   { w: 1200, h: 1920, wL: 1920, hL: 1200 },
  "android-10":  { w: 1600, h: 2560, wL: 2560, hL: 1600 },
  "feature-graphic": { w: 1024, h: 500 },
  "app-store-header": { w: 3840, h: 1646 },
  "app-store-search": { w: 3840, h: 2560 },
  macos:         { w: 2880, h: 1800 },
};

// ---------- Store banners ----------
// Feature graphic (Google Play) plus App Store Connect's product page header
// and search results assets. All three share the "banner" layout.
export const BANNER_DEVICES: Device[] = ["feature-graphic", "app-store-header", "app-store-search"];

export function isBannerDevice(device: Device): boolean {
  return BANNER_DEVICES.includes(device);
}

export type BannerBox = { x: number; y: number; w: number; h: number };

// Apple's "artwork safe area" from its downloadable templates — the region
// that survives every placement's crop, including small featured cards.
// Third-party measurements, so double-check against App Store Connect's
// Preview. Editor-only guide; the layout deliberately ignores it (see
// BANNER_LAYOUT_BOX).
export const BANNER_SAFE_AREA: Partial<Record<Device, BannerBox>> = {
  "app-store-header": { x: 1097, y: 493, w: 1646, h: 661 },
  "app-store-search": { x: 836, y: 765, w: 2168, h: 1030 },
};

// Region the banner layout is fitted into: full height and the middle 84%
// of the width, matching the product page's observed iPhone crop (~8% off
// each side). Featured placements may crop past it. Banners without an
// entry use the whole canvas.
export const BANNER_LAYOUT_BOX: Partial<Record<Device, BannerBox>> = {
  "app-store-header": { x: 307, y: 0, w: 3226, h: 1646 },
  "app-store-search": { x: 307, y: 0, w: 3226, h: 2560 },
};

// Aspect ratio of the reference feature graphic the banner proportions
// were measured on.
const BANNER_REFERENCE_ASPECT = 1024 / 500;

export function bannerLayoutBox(device: Device, cW: number, cH: number): BannerBox {
  return BANNER_LAYOUT_BOX[device] ?? { x: 0, y: 0, w: cW, h: cH };
}

// Size unit for banner text and devices: the height of the largest
// reference-shaped composition that fits the box, so a squarer box (search
// results) doesn't blow the text up to its full height.
export function bannerUnit(box: BannerBox): number {
  return Math.min(box.h, box.w / BANNER_REFERENCE_ASPECT);
}

// App Store Connect rejects images with an alpha channel, and PNG exports
// always carry one — so Apple's banner assets export as JPEG instead.
export function exportsAsJpeg(device: Device): boolean {
  return device === "app-store-header" || device === "app-store-search";
}

// ---------- Export sizes per device ----------
export type ExportSize = { label: string; w: number; h: number };

export const EXPORT_SIZES: Record<Device, ExportSize[]> = {
  iphone: [
    { label: '6.9"', w: 1320, h: 2868 },
    { label: '6.5"', w: 1284, h: 2778 },
    { label: '6.3"', w: 1206, h: 2622 },
    { label: '6.1"', w: 1125, h: 2436 },
  ],
  ipad: [
    { label: '13" iPad',       w: 2064, h: 2752 },
    { label: '12.9" iPad Pro', w: 2048, h: 2732 },
  ],
  android:       [{ label: "Phone",          w: 1080, h: 1920 }],
  "android-7":   [{ label: '7" Portrait',    w: 1200, h: 1920 }],
  "android-10":  [{ label: '10" Portrait',   w: 1600, h: 2560 }],
  "feature-graphic": [{ label: "Feature Graphic", w: 1024, h: 500 }],
  "app-store-header": [{ label: "Header 21:9", w: 3840, h: 1646 }],
  "app-store-search": [{ label: "Search 3:2", w: 3840, h: 2560 }],
  // Apple App Store Connect: macOS screenshots must be exactly one of these
  // four 16:10 sizes — no arbitrary scaling.
  macos: [
    { label: "2880×1800", w: 2880, h: 1800 },
    { label: "2560×1600", w: 2560, h: 1600 },
    { label: "1440×900",  w: 1440, h: 900 },
    { label: "1280×800",  w: 1280, h: 800 },
  ],
};

// Landscape sizes (tablets only)
export const EXPORT_SIZES_LANDSCAPE: Partial<Record<Device, ExportSize[]>> = {
  "android-7":  [{ label: '7" Landscape',  w: 1920, h: 1200 }],
  "android-10": [{ label: '10" Landscape', w: 2560, h: 1600 }],
};

export function supportsLandscape(device: Device): boolean {
  return device in EXPORT_SIZES_LANDSCAPE;
}

export function getExportSizes(device: Device, orientation: Orientation): ExportSize[] {
  if (orientation === "landscape") {
    return EXPORT_SIZES_LANDSCAPE[device] || EXPORT_SIZES[device];
  }
  return EXPORT_SIZES[device];
}

// ---------- Frame aspect ratios ----------
export const MK_RATIO    = 1022 / 2082; // iPhone PNG mockup
export const TAB_P_RATIO = 0.667;        // tablet portrait
export const TAB_L_RATIO = 1.5;          // tablet landscape
export const IPAD_RATIO  = 0.770;        // iPad
export const MAC_RATIO   = 16 / 10;      // macOS App Store screenshot

// Android tablet frames: a 5:8 screen (the capture ratio, so nothing is
// cropped) inside a bezel of equal thickness on all four sides, given as a
// fraction of the screen's short side.
export const ANDROID_TABLET_BEZEL = 0.0376;
export const ANDROID_TABLET_P_RATIO = (1 + 2 * ANDROID_TABLET_BEZEL) / (1.6 + 2 * ANDROID_TABLET_BEZEL);
export const ANDROID_TABLET_L_RATIO = 1 / ANDROID_TABLET_P_RATIO;

// iPhone mockup screen overlay (pre-measured)
export const PHONE_SCREEN = {
  L: (52 / 1022) * 100,
  T: (46 / 2082) * 100,
  W: (918 / 1022) * 100,
  H: (1990 / 2082) * 100,
  RX: (126 / 918) * 100,
  RY: (126 / 1990) * 100,
};

// ---------- Width formula helpers ----------
export function phoneW(cW: number, cH: number, clamp = 0.84) {
  return Math.min(clamp, 0.72 * (cH / cW) * MK_RATIO);
}
export function phoneWSmall(cW: number, cH: number) {
  return phoneW(cW, cH, 0.66);
}
export function tabletPW(cW: number, cH: number, clamp = 0.80) {
  return Math.min(clamp, 0.72 * (cH / cW) * TAB_P_RATIO);
}
export function tabletLW(cW: number, cH: number, clamp = 0.62) {
  return Math.min(clamp, 0.75 * (cH / cW) * TAB_L_RATIO);
}
export function ipadW(cW: number, cH: number, clamp = 0.75) {
  return Math.min(clamp, 0.72 * (cH / cW) * IPAD_RATIO);
}
// Near-full-bleed: unlike the other device types, MacWindow draws no
// bezel/shadow around the screenshot (it's expected to already contain real
// window chrome), so there's no frame that needs breathing room — just a
// hair of margin so the edge doesn't look accidentally cropped.
export function macW(cW: number, cH: number, clamp = 0.98) {
  return Math.min(clamp, (cH / cW) * MAC_RATIO);
}

// ---------- Themes ----------
export const DEFAULT_THEME_ID: ThemeId = "clean-light";

export const THEMES: Record<string, Theme> = {
  "clean-light": {
    id: "clean-light",
    name: "Clean Light",
    bg: "#F6F1EA",
    bgAlt: "#171717",
    fg: "#171717",
    fgAlt: "#F6F1EA",
    accent: "#5B7CFA",
    muted: "#6B7280",
  },
  "dark-bold": {
    id: "dark-bold",
    name: "Dark Bold",
    bg: "#0B1020",
    bgAlt: "#F8FAFC",
    fg: "#F8FAFC",
    fgAlt: "#0B1020",
    accent: "#8B5CF6",
    muted: "#94A3B8",
  },
  "warm-editorial": {
    id: "warm-editorial",
    name: "Warm Editorial",
    bg: "#F7E8DA",
    bgAlt: "#2B1D17",
    fg: "#2B1D17",
    fgAlt: "#F7E8DA",
    accent: "#D97706",
    muted: "#7C5A47",
  },
  "ocean-fresh": {
    id: "ocean-fresh",
    name: "Ocean Fresh",
    bg: "#E0F2FE",
    bgAlt: "#0C4A6E",
    fg: "#0C4A6E",
    fgAlt: "#E0F2FE",
    accent: "#0284C7",
    muted: "#475569",
  },
  "bloom-roast": {
    id: "bloom-roast",
    name: "Bloom Roast",
    bg: "#F2ECE2",
    bgAlt: "#24352F",
    fg: "#1D2420",
    fgAlt: "#FFF7EA",
    accent: "#B8794A",
    muted: "#65736B",
  },
};

export function themeById(themeId: string | undefined): Theme {
  return THEMES[themeId || ""] || THEMES[DEFAULT_THEME_ID];
}

export function hasTheme(themeId: string | undefined): boolean {
  return !!themeId && !!THEMES[themeId];
}

// Resolves a project's base theme: its own inline `theme` (brand-specific,
// owned by that project's config file) takes precedence over `themeId`
// (a reference into the shared THEMES presets below). Reskin-only tenants
// then layer their color overrides on top — headlines/layout are untouched,
// callers keep using the same theme object everywhere colors are read.
export function resolveTheme(
  project: { themeId?: string; theme?: Theme },
  tenants: Tenant[] | undefined,
  activeTenantId: string | undefined,
): Theme {
  const base = project.theme || themeById(project.themeId);
  const tenant = tenants?.find((t) => t.id === activeTenantId);
  return tenant?.colors ? { ...base, ...tenant.colors } : base;
}

export const STORAGE_KEY = "app-store-screenshots:project:v1";
export const PROJECT_SCHEMA_VERSION = 2;
export const LAST_PROJECT_STORAGE_KEY = "app-store-screenshots:last-project";

export const DEVICE_LABEL: Record<Device, string> = {
  iphone: "iPhone",
  ipad: "iPad",
  android: "Android Phone",
  "android-7": 'Android 7" Tablet',
  "android-10": 'Android 10" Tablet',
  "feature-graphic": "Feature Graphic",
  "app-store-header": "Product Page Header",
  "app-store-search": "Search Results",
  macos: "Mac",
};

// ---------- Capture guide ----------
// One recommended real device/simulator per platform to shoot screenshots
// on, at that device's own native resolution. The editor scales a single
// capture into every EXPORT_SIZES/EXPORT_SIZES_LANDSCAPE size on export, so
// there's no need to shoot separately for each required App Store/Play
// Store size — just avoid feeding it a mismatched aspect ratio, which is
// what actually causes visible distortion in the device frame.
export type CaptureGuideEntry = {
  device: Device;
  source: string;
  resolution: string;
};

export const CAPTURE_GUIDE: CaptureGuideEntry[] = [
  { device: "iphone", source: "iPhone 17 Pro simulator", resolution: "1206 × 2622" },
  { device: "ipad", source: "iPad Pro 13-inch (M5) simulator", resolution: "2064 × 2752" },
  {
    device: "android",
    source: 'Pixel phone emulator, or Android Studio\'s generic "Phone" AVD',
    resolution: "1080 × 1920",
  },
  {
    device: "android-7",
    source: "Nexus 7 (2013) emulator profile — rotate for landscape slides",
    resolution: "1200 × 1920",
  },
  {
    device: "android-10",
    source: "Nexus 10 emulator profile (or Pixel C) — rotate for landscape slides",
    resolution: "1600 × 2560",
  },
  {
    device: "feature-graphic",
    source: "Static banner artwork — no device capture needed",
    resolution: "1024 × 500",
  },
  {
    device: "app-store-header",
    source: "Static banner artwork — reuses iPhone/iPad captures",
    resolution: "3840 × 1646",
  },
  {
    device: "app-store-search",
    source: "Static banner artwork — reuses iPhone/iPad captures",
    resolution: "3840 × 2560",
  },
  {
    device: "macos",
    source: "Any display, window captured at exactly this size (Retina 1440×900 @2x)",
    resolution: "2880 × 1800",
  },
];

// Friendly labels for slide layouts (used in dropdowns)
export const LAYOUT_LABEL: Record<SlideLayout, string> = {
  hero: "Hero",
  "device-bottom": "Device bottom",
  "device-top": "Device top",
  "two-devices": "Two devices",
  "no-device": "No device",
  "split-landscape": "Split (landscape)",
  banner: "Banner",
};

// Short description shown under each layout name
export const LAYOUT_HINT: Record<SlideLayout, string> = {
  hero: "Headline above, device at bottom",
  "device-bottom": "Headline top, device anchored below",
  "device-top": "Flipped — device on top",
  "two-devices": "Layered back + front phones",
  "no-device": "Big standalone headline",
  "split-landscape": "Caption left, device right",
  banner: "Icon, name, headline, and subtitle beside two devices",
};
