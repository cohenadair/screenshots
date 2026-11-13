/// The app side of screenshots_capture. A project's capture entrypoint
/// implements [CaptureApp] and passes it to [runCaptures] from `main()`; the
/// host (`bin/capture.dart`) runs it on each device with `flutter run` and
/// takes the screenshots. See the README.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'src/protocol.dart';

// ignore_for_file: avoid_print

/// How long to wait for the host to answer the handshake.
const _handshakeTimeout = Duration(minutes: 3);

/// How long [waitFor] waits for a widget.
const _widgetTimeout = Duration(minutes: 1);

/// How often to check for the host's handshake files.
const _filePollInterval = Duration(milliseconds: 50);

const _widgetPollInterval = Duration(milliseconds: 250);
const _settleStep = Duration(milliseconds: 100);
const _settleTimeout = Duration(seconds: 5);

/// The wait before each screenshot, after the screen has settled, unless
/// the screen sets `delaySeconds`. Longer waits are for content that loads
/// in the background, such as map tiles.
const _defaultDelaySeconds = 1;

/// Length of a locale's script code, e.g. "Hant" in "zh_Hant_TW".
const _scriptCodeLength = 4;

/// What a project implements to be captured.
abstract class CaptureApp {
  /// Replaces the app's data with the seed bundle built by the project's
  /// seed command. Called once, before [launch], if the project has a seed
  /// command.
  Future<void> seed(Directory bundle);

  /// Pumps the app in [locale] (e.g. "en_US") and waits until it's showing.
  Future<void> launch(WidgetTester tester, String locale);

  /// Shows [capture], one of the project's screens: its `screen` and any
  /// other parameters from `capture.json`. Called for each screenshot in
  /// turn, so it should first undo whatever the previous screen left open
  /// (see [resetNavigation]).
  Future<void> show(WidgetTester tester, Map<String, dynamic> capture);
}

/// Seeds and launches [app], then shows each screen the host asks for and
/// waits while the host takes the screenshot.
void runCaptures(CaptureApp app) {
  // Render every frame the app requests, as it would outside of a test, so
  // animations, maps, and images finish on their own while waiting.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets("Capture screenshots", timeout: Timeout.none, (tester) async {
    // Apps often replace the test framework's error handler (e.g. with
    // Crashlytics). Restore it even on failure, or the test hangs instead of
    // failing.
    var onError = FlutterError.onError;
    try {
      await _captureAll(tester, app);
    } catch (e) {
      _send(commandFailed, "$e".replaceAll("\n", " "));
      rethrow;
    } finally {
      FlutterError.onError = onError;
    }
  });
}

/// Shows [message] in the host's output.
void captureLog(String message) => _send(commandLog, message);

/// Like [WidgetTester.pumpAndSettle], but doesn't fail on screens with
/// never-ending animations (e.g. a loading map); they're just given time.
Future<void> settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      _settleStep,
      EnginePhase.sendSemanticsUpdate,
      _settleTimeout,
    );
  } on FlutterError catch (_) {
    captureLog("Screen didn't settle; continuing");
  }
}

Future<void> wait(Duration duration) => Future.delayed(duration);

/// Pumps until [finder] finds something, failing after a minute.
Future<void> waitFor(WidgetTester tester, Finder finder) => waitUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  description: "$finder",
);

/// Pumps until [isDone] returns true, failing after a minute. For state the
/// app sets asynchronously, such as a platform view finishing its setup.
Future<void> waitUntil(
  WidgetTester tester,
  bool Function() isDone, {
  required String description,
}) async {
  var end = DateTime.now().add(_widgetTimeout);
  while (!isDone()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError("Timed out waiting for $description");
    }
    await tester.pump(_widgetPollInterval);
  }
}

/// Pops every navigator (including dialogs and pickers, which are routes)
/// back to its first route, so each screen starts from the app's home.
Future<void> resetNavigation(WidgetTester tester) async {
  for (var navigator in tester.stateList<NavigatorState>(
    find.byType(Navigator, skipOffstage: false),
  )) {
    // A navigator inside a route popped by an earlier one may be gone.
    if (navigator.mounted) {
      navigator.popUntil((route) => route.isFirst);
    }
  }
  await settle(tester);
}

/// Selects tab [index] of the app's [BottomNavigationBar] or
/// [NavigationBar], by calling its callback rather than tapping, so no touch
/// indicator is drawn on the screenshot.
Future<void> selectTab(WidgetTester tester, int index) async {
  var bottomBars = find.byType(BottomNavigationBar);
  if (bottomBars.evaluate().isEmpty) {
    tester
        .widget<NavigationBar>(find.byType(NavigationBar))
        .onDestinationSelected!(index);
  } else {
    tester.widget<BottomNavigationBar>(bottomBars).onTap!(index);
  }
  await settle(tester);
}

/// Pushes [page] onto the navigator that contains [within], e.g. a tab's
/// root page in an app with a navigator per tab.
Future<void> pushPage(WidgetTester tester, Finder within, Widget page) async {
  Navigator.of(
    tester.element(within),
  ).push(MaterialPageRoute(builder: (_) => page));
  await settle(tester);
}

/// Parses a locale such as "es", "en_US", or "zh_Hant_TW".
Locale parseLocale(String locale) {
  var parts = locale.split("_");
  return Locale.fromSubtags(
    languageCode: parts.first,
    scriptCode: parts
        .skip(1)
        .where((e) => e.length == _scriptCodeLength)
        .firstOrNull,
    countryCode: parts
        .skip(1)
        .where((e) => e.length != _scriptCodeLength)
        .firstOrNull,
  );
}

Future<void> _captureAll(WidgetTester tester, CaptureApp app) async {
  var dir = Directory(
    "${(await getApplicationDocumentsDirectory()).path}/$handshakeDirName",
  );
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);

  _send(commandReady, dir.path);
  await _waitForFile(File("${dir.path}/$readyFile"));

  var plan =
      jsonDecode(File("${dir.path}/$planFile").readAsStringSync())
          as Map<String, dynamic>;
  var locale = plan["locale"] as String;

  if (plan["isSeeded"] == true) {
    await app.seed(Directory("${dir.path}/$seedDir"));
  }
  await app.launch(tester, locale);
  captureLog("Launched in $locale");

  for (var capture in (plan["captures"] as List).cast<Map>()) {
    var name = capture["name"] as String;
    await app.show(tester, capture.cast<String, dynamic>());
    await wait(
      Duration(
        milliseconds:
            (((capture["delaySeconds"] as num?) ?? _defaultDelaySeconds) *
                    Duration.millisecondsPerSecond)
                .round(),
      ),
    );

    _send(commandCapture, name);
    await _waitForFile(File("${dir.path}/${ackFile(name)}"));
  }

  _send(commandDone);
}

void _send(String command, [String argument = ""]) =>
    print("$marker$command $argument".trimRight());

Future<void> _waitForFile(File file) async {
  var end = DateTime.now().add(_handshakeTimeout);
  while (!file.existsSync()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError("Timed out waiting for ${file.path}");
    }
    await wait(_filePollInterval);
  }
}
