import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'config.dart';
import 'device.dart';
import 'process.dart';

// ignore_for_file: avoid_print

/// An Android emulator, by AVD name (`"avd"` in `capture.json`).
class AndroidDevice extends Device {
  // Flutter runs Dart on Android's main thread, so a slow, large-screen
  // emulator shows "isn't responding" dialogs. These override the AVD's own
  // (often small) defaults.
  static const _emulatorCores = 6;
  static const _emulatorMemoryMb = 4096;

  static const _emulatorStartTimeout = Duration(minutes: 3);
  static const _bootTimeout = Duration(minutes: 5);
  static const _rotationTimeout = Duration(seconds: 3);

  /// `user_rotation` values to try, in order: natural, then 90° and 270°.
  static const _rotations = [0, 1, 3];

  /// Buttons to tap on system dialogs, in order of preference.
  ///
  /// Google Play services asks to turn on Location Accuracy when the app
  /// requests a location. It can't be turned on in an emulator, so it may
  /// come back, but "Turn on" keeps the app's location stream alive
  /// ("No thanks" ends it). "Wait" dismisses an "isn't responding" dialog,
  /// which a slow emulator can show while the app is busy.
  static const _dialogDismissLabels = ["Turn on", "No thanks", _waitLabel];

  static const _maxDialogDismissals = 5;
  static const _maxDumpAttempts = 3;
  static const _dialogDismissDelay = Duration(seconds: 2);

  /// "Wait" means the app was stuck, so give it longer to catch up (e.g.
  /// finish moving a map) before the screenshot.
  static const _waitLabel = "Wait";
  static const _appRecoveryDelay = Duration(seconds: 10);

  /// `capture.json` permissions to Android runtime permissions.
  static const _runtimePermissions = {
    CaptureConfig.permissionLocation: [
      "ACCESS_FINE_LOCATION",
      "ACCESS_COARSE_LOCATION",
    ],
    CaptureConfig.permissionNotifications: ["POST_NOTIFICATIONS"],
    CaptureConfig.permissionPhotos: ["READ_MEDIA_IMAGES"],
  };

  static const _deviceTar = "/data/local/tmp/screenshots-capture.tar";

  String? _serial;
  Process? _emulator;
  String? _handshakeDir;

  /// The most recent UI hierarchy dump, kept for debugging.
  var _lastDump = "";

  AndroidDevice(super.name, super.spec, super.config, super.workDir);

  @override
  String get id => _serial!;

  String get _package => config.androidPackage!;

  static String get _sdk =>
      Platform.environment["ANDROID_HOME"] ??
      Platform.environment["ANDROID_SDK_ROOT"] ??
      "${Platform.environment["HOME"]}/Library/Android/sdk";

  static String get _adbPath => "$_sdk/platform-tools/adb";

  Future<String> _adb(List<String> args, {bool allowFailure = false}) =>
      run(_adbPath, ["-s", id, ...args], allowFailure: allowFailure);

  Future<String> _shell(String command, {bool allowFailure = false}) =>
      _adb(["shell", command], allowFailure: allowFailure);

  @override
  Future<void> boot() async {
    var avd = spec["avd"] as String;
    var serial = await _findEmulator(avd);
    if (serial == null) {
      print("[$name] Booting $avd...");
      _emulator = await Process.start("$_sdk/emulator/emulator", [
        "-avd",
        avd,
        "-no-boot-anim",
        "-no-audio",
        "-no-snapshot-save",
        "-cores",
        "$_emulatorCores",
        "-memory",
        "$_emulatorMemoryMb",
      ], mode: ProcessStartMode.detached);
      didBoot = true;

      try {
        await waitUntil(
          () async => (serial = await _findEmulator(avd)) != null,
          timeout: _emulatorStartTimeout,
          message: "Timed out starting emulator $avd",
        );
      } on Exception {
        // It never connected, so it can't be shut down with adb.
        _emulator?.kill();
        rethrow;
      }
    }
    _serial = serial;

    await waitUntil(
      () async =>
          await _shell("getprop sys.boot_completed", allowFailure: true) == "1",
      timeout: _bootTimeout,
      message: "Timed out waiting for $avd to boot",
    );
  }

  Future<String?> _findEmulator(String avd) async {
    for (var line in LineSplitter.split(await run(_adbPath, ["devices"]))) {
      var parts = line.split(RegExp(r"\s+"));
      if (parts.length < 2 ||
          !parts[0].startsWith("emulator-") ||
          parts[1] != "device") {
        continue;
      }
      var output = await run(_adbPath, [
        "-s",
        parts[0],
        "emu",
        "avd",
        "name",
      ], allowFailure: true);
      if (LineSplitter.split(output).firstOrNull?.trim() == avd) {
        return parts[0];
      }
    }
    return null;
  }

  @override
  Future<void> prepare(List<num>? location) async {
    var time = Device.statusBarTime.padLeft(5, "0").replaceAll(":", "");
    var level = Device.statusBarSignalBars;
    await _shell(
      [
        "cmd uimode night no",
        "settings put global sysui_demo_allowed 1",
        for (var command in [
          "-e command enter",
          "-e command clock -e hhmm $time",
          "-e command battery -e level ${Device.statusBarBatteryLevel} "
              "-e plugged false",
          "-e command network -e wifi show -e level $level -e fully true",
          "-e command network -e mobile show -e datatype none -e level $level",
          "-e command notifications -e visible false",
        ])
          "am broadcast -a com.android.systemui.demo $command >/dev/null",
        "cmd statusbar collapse",
      ].join(" && "),
    );
    if (location == null) {
      return;
    }
    await _adb(["emu", "geo", "fix", "${location[1]}", "${location[0]}"]);
  }

  @override
  Future<void> ensureOrientation(String orientation) async {
    expectedOrientation = orientation;
    await _shell("settings put system accelerometer_rotation 0");
    var path = "$workDir/orientation-$name.png";
    for (var rotation in _rotations) {
      await _shell("settings put system user_rotation $rotation");
      try {
        await waitUntil(
          () async {
            await screenshot(path);
            return orientationOf(path) == orientation;
          },
          timeout: _rotationTimeout,
          message: "Not $orientation at rotation $rotation",
        );
        return;
      } on Exception {
        // Try the next rotation.
      }
    }
    throw Exception("Couldn't rotate ${spec["avd"]} to $orientation");
  }

  @override
  Future<void> onAppReady(
    String dir,
    Map<String, dynamic> plan,
    String? seedBundle,
  ) async {
    _handshakeDir = dir;
    var grants = [
      for (var permission in config.permissions)
        for (var name in _runtimePermissions[permission] ?? const <String>[])
          // Fails harmlessly for permissions the app doesn't declare.
          "pm grant $_package android.permission.$name 2>/dev/null",
    ];
    if (grants.isNotEmpty) {
      await _shell(grants.join("; "), allowFailure: true);
    }

    // App data is only writable by the app, so stream a tar through run-as.
    var staging = Directory("$workDir/android-$name");
    if (staging.existsSync()) {
      staging.deleteSync(recursive: true);
    }
    staging.createSync(recursive: true);
    if (seedBundle != null) {
      await run("cp", ["-R", seedBundle, "${staging.path}/$seedDir"]);
    }
    File("${staging.path}/$planFile").writeAsStringSync(jsonEncode(plan));

    var tar = "$workDir/android-$name.tar";
    await run(
      "tar",
      ["-cf", tar, "-C", staging.path, "."],
      // Keeps macOS from adding AppleDouble "._" files.
      environment: {"COPYFILE_DISABLE": "1"},
    );
    await _adb(["push", tar, _deviceTar]);
    await _shell(
      "cat $_deviceTar | run-as $_package tar -xf - -C $dir && "
      "run-as $_package touch $dir/$readyFile",
    );
  }

  @override
  Future<void> beforeScreenshot() async {
    await _shell("cmd statusbar collapse");

    // Dismissing one dialog can reveal another, so check until none are left.
    for (var i = 0; i < _maxDialogDismissals; i++) {
      if (!await _dismissDialog()) {
        return;
      }
    }
    var debugPath = "$workDir/logs/$name-dialog";
    await screenshot("$debugPath.png");
    File("$debugPath.xml").writeAsStringSync(_lastDump);
    throw Exception("System dialogs kept appearing; see $debugPath.png");
  }

  /// Taps the first [_dialogDismissLabels] button on screen that isn't part
  /// of the app. Returns false if there wasn't one.
  Future<bool> _dismissDialog() async {
    // `uiautomator dump` takes seconds, so skip it when the app itself has
    // focus. System dialogs, including "isn't responding", take focus.
    var focus = await _shell(
      "dumpsys window | grep mCurrentFocus",
      allowFailure: true,
    );
    if (focus.contains("$_package/")) {
      return false;
    }

    _lastDump = await _dumpUi();
    for (var label in _dialogDismissLabels) {
      for (var node in _lastDump.split("<node ").skip(1)) {
        if (_attribute(node, "text") != label ||
            _attribute(node, "package") == _package) {
          continue;
        }
        var bounds = RegExp(
          r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
        ).firstMatch(_attribute(node, "bounds") ?? "");
        if (bounds == null) {
          continue;
        }
        var b = [for (var i = 1; i <= 4; i++) int.parse(bounds.group(i)!)];
        var x = (b[0] + b[2]) ~/ 2;
        var y = (b[1] + b[3]) ~/ 2;
        await _shell("input tap $x $y");
        print("[$name] Tapped \"$label\" ($x, $y) on a system dialog");
        await Future.delayed(
          label == _waitLabel ? _appRecoveryDelay : _dialogDismissDelay,
        );
        return true;
      }
    }
    return false;
  }

  /// The UI hierarchy as XML. Retries because `uiautomator dump` often fails
  /// while the screen is animating (e.g. a map loading).
  Future<String> _dumpUi() async {
    for (var i = 0; i < _maxDumpAttempts; i++) {
      var dump = await _shell(
        "uiautomator dump /sdcard/window.xml >/dev/null && "
        "cat /sdcard/window.xml",
        allowFailure: true,
      );
      if (dump.contains("<hierarchy")) {
        return dump;
      }
      await Future.delayed(Device.pollInterval);
    }
    print("[$name] Warning: couldn't read the screen to check for dialogs");
    return "";
  }

  static String? _attribute(String node, String name) =>
      RegExp("\\b$name=\"([^\"]*)\"").firstMatch(node)?.group(1);

  @override
  Future<void> screenshot(String path) async => File(path).writeAsBytesSync(
    await runBytes(_adbPath, ["-s", id, "exec-out", "screencap", "-p"]),
  );

  @override
  Future<void> ack(String name) =>
      _shell("run-as $_package touch $_handshakeDir/${ackFile(name)}");

  @override
  Future<void> cleanUp({required bool shutDown}) async {
    if (_serial == null) {
      return;
    }
    if (shutDown && didBoot) {
      await _adb(["emu", "kill"], allowFailure: true);
      return;
    }
    await _shell(
      "am broadcast -a com.android.systemui.demo -e command exit",
      allowFailure: true,
    );
  }
}
