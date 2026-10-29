import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'config.dart';
import 'device.dart';
import 'process.dart';

// ignore_for_file: avoid_print

/// An iOS simulator, by name (`"simulator"` in `capture.json`).
class IosDevice extends Device {
  static const _bootTimeout = Duration(minutes: 10);
  static const _wifiBars = 3;
  static const _grantTimeout = Duration(seconds: 20);
  static const _maxGrantAttempts = 3;

  /// `capture.json` permissions to `simctl privacy` services. Notifications
  /// can't be granted on a simulator.
  static const _privacyServices = {
    CaptureConfig.permissionLocation: ["location", "location-always"],
    CaptureConfig.permissionPhotos: ["photos"],
  };

  String? _udid;
  String? _handshakeDir;

  IosDevice(super.name, super.spec, super.config, super.workDir);

  @override
  String get id => _udid!;

  @override
  Future<void> boot() async {
    var simulator = spec["simulator"] as String;
    var json =
        jsonDecode(
              await run("xcrun", ["simctl", "list", "devices", "-j"]),
            )["devices"]
            as Map<String, dynamic>;

    // Prefer the newest runtime with a simulator of this name.
    var runtimes = json.keys.toList()
      ..sort((a, b) => _compareVersions(_version(b), _version(a)));
    Map<String, dynamic>? match;
    for (var runtime in runtimes) {
      match = (json[runtime] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e["name"] == simulator && e["isAvailable"] == true)
          .firstOrNull;
      if (match != null) {
        break;
      }
    }
    if (match == null) {
      throw Exception("No available simulator named \"$simulator\"");
    }

    _udid = match["udid"] as String;
    if (match["state"] != "Booted") {
      print("[$name] Booting $simulator...");
      await run("xcrun", ["simctl", "boot", id]);
      didBoot = true;
    }
    await run("xcrun", [
      "simctl",
      "bootstatus",
      id,
      "-b",
    ], timeout: _bootTimeout);
  }

  @override
  Future<void> prepare(List<num>? location) async {
    await run("xcrun", ["simctl", "ui", id, "appearance", "light"]);
    await run("xcrun", [
      "simctl",
      "status_bar",
      id,
      "override",
      "--time",
      Device.statusBarTime,
      "--dataNetwork",
      "wifi",
      "--wifiMode",
      "active",
      "--wifiBars",
      "$_wifiBars",
      "--cellularMode",
      "active",
      "--cellularBars",
      "${Device.statusBarSignalBars}",
      "--operatorName",
      "",
      "--batteryState",
      "charged",
      "--batteryLevel",
      "${Device.statusBarBatteryLevel}",
    ]);
    if (location == null) {
      return;
    }
    await run("xcrun", [
      "simctl",
      "location",
      id,
      "set",
      "${location[0]},${location[1]}",
    ]);
  }

  @override
  Future<void> ensureOrientation(String orientation) async {
    expectedOrientation = orientation;
    var path = "$workDir/orientation-$name.png";
    await screenshot(path);
    if (orientationOf(path) != orientation) {
      throw Exception(
        "Rotate the \"${spec["simulator"]}\" simulator to $orientation "
        "(Device > Rotate in Simulator.app), then re-run",
      );
    }
  }

  @override
  Future<void> onAppReady(
    String dir,
    Map<String, dynamic> plan,
    String? seedBundle,
  ) async {
    // Installing the app can reset its permissions, so grant them now; the
    // app hasn't asked for them yet.
    for (var permission in config.permissions) {
      for (var service in _privacyServices[permission] ?? const <String>[]) {
        await _grant(service);
      }
    }

    // The simulator's file system is the host's, so copy directly.
    _handshakeDir = dir;
    if (seedBundle != null) {
      await run("cp", ["-R", seedBundle, "$dir/$seedDir"]);
    }
    File("$dir/$planFile").writeAsStringSync(jsonEncode(plan));
    File("$dir/$readyFile").createSync();
  }

  /// Grants [service]. `simctl privacy` occasionally hangs while the
  /// simulator is busy, so it's retried, and a failure only warns: the app
  /// asks for the permission itself if it's still needed.
  Future<void> _grant(String service) async {
    for (var attempt = 1; attempt <= _maxGrantAttempts; attempt++) {
      try {
        await run("xcrun", [
          "simctl",
          "privacy",
          id,
          "grant",
          service,
          config.iosBundleId!,
        ], timeout: _grantTimeout);
        return;
      } on Exception catch (e) {
        if (attempt == _maxGrantAttempts) {
          print("[$name] Warning: couldn't grant $service: $e");
        }
      }
    }
  }

  @override
  Future<void> screenshot(String path) =>
      run("xcrun", ["simctl", "io", id, "screenshot", "--type=png", path]);

  @override
  Future<void> ack(String name) async =>
      File("$_handshakeDir/${ackFile(name)}").createSync();

  @override
  Future<void> cleanUp({required bool shutDown}) async {
    if (_udid == null) {
      return;
    }
    if (shutDown && didBoot) {
      await run("xcrun", ["simctl", "shutdown", id], allowFailure: true);
      return;
    }
    await run("xcrun", [
      "simctl",
      "status_bar",
      id,
      "clear",
    ], allowFailure: true);
  }

  /// The version numbers in a runtime ID, e.g. `[26, 1]` for
  /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1`.
  static List<int> _version(String runtime) => RegExp(
    r"\d+",
  ).allMatches(runtime).map((e) => int.parse(e.group(0)!)).toList();

  static int _compareVersions(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) {
        return a[i].compareTo(b[i]);
      }
    }
    return a.length.compareTo(b.length);
  }
}
