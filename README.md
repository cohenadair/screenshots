# Screenshots

Shared tools for every app in the workspace's App Store / Google Play
screenshots. Neither holds project data; each app keeps its own
configuration in its own repo and registers it in the tool's
`projects.json`.

| Folder | What it does |
| --- | --- |
| [`studio/`](studio) | A Next.js editor for designing the marketing slides (captions, layouts, device frames) and exporting them at every store size. |
| [`capture/`](capture) | A Dart CLI that captures the raw device screenshots the studio uses: it seeds the app, drives it to each screen on iOS simulators and Android emulators in every locale, and writes the PNGs into the project's studio assets. |

The usual flow for a project that uses both (e.g. Anglers' Log):

1. Capture: from `capture/`, `dart run bin/capture.dart <project>`.
2. Design and export: from `studio/`, `pnpm dev`, then pick the project.

See each folder's README for details.
