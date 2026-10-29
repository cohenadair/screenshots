# Capture

Captures App Store / Google Play screenshots of a Flutter app on iOS
simulators and Android emulators, in every locale, and writes them straight
into the project's [studio](../studio) assets. Open the studio afterwards
and the new captures are already in the deck.

Like the studio, this is one shared tool for every project in the
workspace. It holds no project data: each project keeps its own
configuration (seed data, screens, and an app-side entrypoint) in its own
repo, and registers it in [`projects.json`](projects.json).

Normally run through the `capture-store-screenshots` Claude skill. By hand,
from this directory:

```bash
dart run bin/capture.dart anglers-log
```

| Option | |
| --- | --- |
| `--devices iphone,ipad` | Devices from the project's `capture.json` (default: all). |
| `--locales en,es` | Locales from `capture.json` (default: all). |
| `--only 01,04` | Capture only these file names. |
| `--keep-running` | Don't shut down simulators/emulators this run booted. |
| `-- <args>` | Passed to the project's seed command, e.g. `-- --placeholder-photos`. |

The project can also be a path to a `capture.json` (or its folder) instead of
an id.

## How a run works

Devices run one at a time. Running simulators and emulators side by side
starves them of CPU, and Android then shows "isn't responding" dialogs.

1. **Seed and build.** While the first device boots, the project's seed
   command runs once per locale and writes a bundle (whatever the project's
   app side knows how to load) into
   `<app>/build/screenshots-capture/seed-<locale>/`. The entrypoint is built
   once per platform (`flutter build ios --simulator` / `flutter build apk`,
   both debug), and every device and locale reuses that build.
2. **Devices.** Each simulator/emulator is booted if needed and given a 9:41,
   full-battery status bar, light mode, the configured location, and the
   orientation the deck expects (landscape if the device's slides are
   landscape-only). Emulators this tool boots get 6 cores and 4 GB of RAM;
   with less, large screens trigger "isn't responding" dialogs.
3. **Capture.** For each locale, the build is run with
   `flutter run --use-application-binary <build> -d <device>`, then:
   - The app prints `READY`. The host grants the configured permissions,
     copies the seed bundle and a capture plan into the app's documents
     folder, and signals it to continue.
   - The app seeds itself, launches, and for each screen prints `CAPTURE`.
     The host clears system UI (Android: collapses the notification shade and
     dismisses system dialogs that aren't the app's), takes a native
     screenshot (`simctl io` / `adb screencap`, so the status bar and
     platform views like maps are included), checks its orientation, and
     acknowledges.
   - The app prints `DONE` and the host quits `flutter run`.
4. **Publish.** Once every locale succeeds on a device, its PNGs are copied to
   `<assets>/<output>/<locale>/`. Logs (and debugging screenshots if Android
   dialogs won't go away) are in `<app>/build/screenshots-capture/logs/`.

Building and running a different entrypoint (`-t`) points Xcode's
`FLUTTER_TARGET` (in `ios/Flutter/Generated.xcconfig`) at it, so a later
Run or Archive in Xcode would build the capture app. The tool restores
those files when it finishes; if a run is killed, any `flutter run` or
`flutter build` of the app fixes them.

The handshake itself is described in
[`lib/src/protocol.dart`](lib/src/protocol.dart).

## Adding a project

A project's capture folder (e.g.
[`anglers-log/screenshots/capture`](../../anglers-log/screenshots/capture))
contains:

- **`capture.json`**, the configuration (below).
- **An entrypoint** that implements `CaptureApp` and calls `runCaptures`:

  ```dart
  import 'package:screenshots_capture/screenshots_capture.dart';

  void main() => runCaptures(MyCapture());

  class MyCapture implements CaptureApp {
    @override
    Future<void> seed(Directory bundle) async { /* load the bundle */ }

    @override
    Future<void> launch(WidgetTester tester, String locale) async {
      await tester.pumpWidget(MyApp(locale: parseLocale(locale)));
    }

    @override
    Future<void> show(WidgetTester tester, Map<String, dynamic> capture) async {
      await resetNavigation(tester);
      // Then go to capture["screen"], e.g. with selectTab and pushPage.
    }
  }
  ```

  It runs with the app's packages, so it can import the app's code. The
  library also exports helpers:
  - navigation: `resetNavigation`, `selectTab` (bottom navigation bar),
    `pushPage`;
  - waiting: `settle`, `waitFor`, `waitUntil`, `wait`;
  - `parseLocale` and `captureLog`.

  Navigate by calling callbacks or pushing routes rather than tapping where
  possible, so no touch indicators are drawn. To unlock Pro features, install a stub
  `SubscriptionManager` in `launch` (see Anglers' Log's `capture_app.dart`).
- **A seed command** (optional), e.g. a Dart script that builds the bundle.
  [`package:screenshots_capture/seed.dart`](lib/seed.dart) has the generic
  parts, without Flutter so it runs with `dart run`:
  - `runSeedCli`: `--check`, `--locale`, `--out`, `--placeholder-photos`;
  - `SeedClock`: relative timestamps such as `"-3d 06:42"`, so seed data
    never goes stale;
  - `SeedTranslations`: `seed/translations/<locale>.json` files;
  - `SeedPhotos`: `seed/photos/`, converted to JPEG, with placeholders;
  - `seedUuid`, `collectStrings`, and `pubspecVersion`.
- **A `pubspec.yaml`** depending on the app (by path) and
  `screenshots_capture`, so the entrypoint and seed script analyze cleanly in
  the IDE.

Then:

1. Add `screenshots_capture` (by path) to the app's `dev_dependencies`.
2. Register the project in [`projects.json`](projects.json).
3. Create the simulators/AVDs named in `capture.json` if they don't exist.

### `capture.json`

Paths are relative to the file.

| Key | |
| --- | --- |
| `app` | The Flutter app's root (where `flutter run` runs). |
| `entrypoint` | The app-side entrypoint. |
| `assets` | The project's studio folder (holds `app-store-screenshots.json`). |
| `ios.bundleId`, `android.package` | For permissions and file transfer. Required if any device uses that platform. |
| `deviceLocation` | Optional. `[lat, lng]` given to every simulator/emulator. |
| `permissions` | Optional. Granted before the app launches: `location`, `notifications` (Android only), `photos`. |
| `flutterArgs` | Optional. Extra arguments for `flutter build` and `flutter run`, e.g. `["--flavor", "prod"]`. |
| `seed.command` | Run in this folder per locale. `{locale}` (deck locale, e.g. `es`), `{appLocale}` (e.g. `es_MX`) and `{out}` (the bundle directory) are substituted. |
| `locales` | Deck locale → locale the app is launched in. |
| `devices` | Name → `{"platform": "ios", "simulator": "<name>"}` or `{"platform": "android", "avd": "<name>"}`, plus `output`, the screenshot folder under `assets` (e.g. `screenshots/apple/iphone`). |
| `screens` | Name → the parameters passed to `CaptureApp.show`. `screen` and everything else is up to the project, except `delaySeconds` (wait after the screen settles, before capturing; default 1, longer for content that loads in the background such as map tiles). |
| `captures` | Device → file name (e.g. `01`) → screen name. Files the deck uses but nothing captures are reported as warnings. |
