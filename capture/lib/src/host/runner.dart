import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'android_device.dart';
import 'config.dart';
import 'device.dart';
import 'ios_device.dart';
import 'process.dart' as host;

// ignore_for_file: avoid_print

/// Captures [config]'s screenshots and publishes them to its studio assets.
///
/// The app is built once per platform, then each device runs that build once
/// per locale. Devices run one at a time, since emulators and simulators
/// running side by side starve each other of CPU (Android then shows "isn't
/// responding" dialogs); seeding and building overlap the first boot.
class Runner {
  /// How long the app can go without a handshake message before the run is
  /// considered stuck.
  static const _silenceTimeout = Duration(minutes: 10);

  /// How long `flutter run` gets to quit before it's terminated, and then
  /// killed.
  static const _quitTimeout = Duration(seconds: 30);

  static const _buildTimeout = Duration(minutes: 30);

  /// What `flutter run` prints when it can't see the device yet, which
  /// happens briefly after an emulator boots even though adb sees it.
  static const _deviceNotFound = "No supported devices found";
  static const _maxLaunchAttempts = 3;
  static const _launchRetryDelay = Duration(seconds: 5);

  /// Files `flutter build ios` and `flutter run -t` rewrite to point at the
  /// capture entrypoint. Xcode uses them, so they're restored after a run.
  static const _xcodeTargetFiles = [
    "ios/Flutter/Generated.xcconfig",
    "ios/Flutter/flutter_export_environment.sh",
  ];

  final CaptureConfig config;
  final List<String> devices;
  final List<String> locales;
  final List<String>? only;
  final bool keepRunning;

  /// Extra arguments for the project's seed command.
  final List<String> seedArgs;

  late final Map<String, dynamic> _deck =
      jsonDecode(File(config.deckPath).readAsStringSync())
          as Map<String, dynamic>;

  Runner({
    required this.config,
    required this.devices,
    required this.locales,
    required this.only,
    required this.keepRunning,
    required this.seedArgs,
  });

  /// Working files, inside the app's (ignored) build directory.
  String get _workDir => "${config.appDir}/build/screenshots-capture";

  /// Returns false if any device failed.
  Future<bool> run() async {
    _validate();
    var captures = {for (var device in devices) device: _capturesFor(device)}
      ..removeWhere((device, captures) => captures.isEmpty);
    if (captures.isEmpty) {
      print("Nothing to capture.");
      return true;
    }
    Directory("$_workDir/logs").createSync(recursive: true);

    var xcodeFiles = _backUpXcodeTargetFiles();
    var failures = <String>[];
    try {
      var seeds = _buildSeeds();
      var platforms = captures.keys.map(config.platform).toSet();
      var binaries = _buildApps(platforms);

      // Unhandled until a device awaits them; a failure fails each device.
      seeds.ignore();
      for (var binary in binaries.values) {
        binary.ignore();
      }

      await _runDevices(captures, seeds, binaries, failures);
    } finally {
      _restoreXcodeTargetFiles(xcodeFiles);
    }

    print("");
    if (failures.isEmpty) {
      print("All screenshots captured.");
      return true;
    }
    print("Failed devices:");
    failures.forEach(print);
    return false;
  }

  /// Captures each device in [captures], one after another.
  Future<void> _runDevices(
    Map<String, List<Map<String, dynamic>>> captures,
    Future<Map<String, String>> seeds,
    Map<String, Future<String>> binaries,
    List<String> failures,
  ) async {
    for (var name in captures.keys) {
      var spec = config.devices[name] as Map<String, dynamic>;
      var device = config.platform(name) == CaptureConfig.platformIos
          ? IosDevice(name, spec, config, _workDir)
          : AndroidDevice(name, spec, config, _workDir);

      try {
        await device.boot();
        await device.prepare(config.deviceLocation);
        await device.ensureOrientation(_orientation(spec));

        var outDir = "$_workDir/out/$name";
        for (var locale in locales) {
          await _captureLocale(
            device,
            locale,
            captures[name]!,
            (await seeds)[locale],
            await binaries[config.platform(name)]!,
            "$outDir/$locale",
          );
        }
        _publish(spec, outDir);
      } catch (e) {
        failures.add("$name: $e");
        print("[$name] FAILED: $e");
      } finally {
        try {
          await device.cleanUp(shutDown: !keepRunning);
        } catch (e) {
          print("[$name] Couldn't clean up: $e");
        }
      }
    }
  }

  /// Deck slides whose screenshot lives in [spec]'s output directory.
  Iterable<Map<String, dynamic>> _deckSlides(Map<String, dynamic> spec) {
    var prefix = "${spec["output"]}/";
    return (_deck["slidesByDevice"] as Map<String, dynamic>).values
        .expand((e) => (e as List).cast<Map<String, dynamic>>())
        .where((e) => (e["screenshot"] as String? ?? "").startsWith(prefix));
  }

  /// Landscape if any deck slide using [spec]'s screenshots is landscape-only.
  String _orientation(Map<String, dynamic> spec) =>
      _deckSlides(
        spec,
      ).any((e) => e["orientationFilter"] == Device.orientationLandscape)
      ? Device.orientationLandscape
      : Device.orientationPortrait;

  /// The plan entries for [device] in this run: each file name and its
  /// screen's parameters.
  List<Map<String, dynamic>> _capturesFor(String device) => [
    for (var MapEntry(key: file, value: screen)
        in config.captures(device).entries)
      if (only == null || only!.contains(file))
        {"name": file, ...config.screens[screen] as Map<String, dynamic>},
  ];

  /// Fails on unknown devices, locales, screens, and config problems, and
  /// warns about deck screenshots that nothing captures.
  void _validate() {
    var problems = config.validate();
    for (var device in devices) {
      if (!config.devices.containsKey(device)) {
        problems.add("Unknown device \"$device\"");
      }
    }
    for (var locale in locales) {
      if (!config.locales.containsKey(locale)) {
        problems.add("Unknown locale \"$locale\"");
      }
    }
    if (problems.isNotEmpty) {
      throw ArgumentError("${problems.join("\n")}\nSee ${config.path}");
    }

    var deckLocales = (_deck["locales"] as List).cast<String>();
    for (var locale in locales) {
      if (!deckLocales.contains(locale)) {
        print("Warning: locale \"$locale\" isn't in the deck's locales.");
      }
    }

    var files = <String>{};
    for (var device in devices) {
      var spec = config.devices[device] as Map<String, dynamic>;
      var captures = config.captures(device);
      files.addAll(captures.keys);
      for (var MapEntry(key: file, value: screen) in captures.entries) {
        if (!config.screens.containsKey(screen)) {
          throw ArgumentError("$device/$file: unknown screen \"$screen\"");
        }
      }

      var expected = _deckSlides(spec)
          .map((e) => (e["screenshot"] as String).split("/").last)
          .map((e) => e.replaceAll(".png", ""))
          .toSet();
      for (var file in expected.difference(captures.keys.toSet())) {
        print(
          "Warning: deck uses ${spec["output"]}/{locale}/$file.png, "
          "but capture.json doesn't capture it.",
        );
      }
    }

    for (var file in only ?? const <String>[]) {
      if (!files.contains(file)) {
        print("Warning: no device captures \"$file\".");
      }
    }
  }

  /// Runs the project's seed command for each locale. Returns each locale's
  /// bundle directory.
  Future<Map<String, String>> _buildSeeds() async {
    var command = config.seedCommand;
    if (command == null) {
      return {};
    }

    var bundles = <String, String>{};
    for (var locale in locales) {
      var out = "$_workDir/seed-$locale";
      print("Building $locale seed bundle...");
      await host.run(
        command.first,
        [
          for (var arg in command.skip(1))
            arg
                .replaceAll("{locale}", locale)
                .replaceAll("{appLocale}", config.locales[locale]!)
                .replaceAll("{out}", out),
          ...seedArgs,
        ],
        workingDirectory: config.dir,
        timeout: _buildTimeout,
      );
      bundles[locale] = out;
    }
    return bundles;
  }

  /// Builds the capture entrypoint once for each of [platforms]. Returns the
  /// path of each platform's app binary.
  ///
  /// The builds run one after the other; two `flutter build`s in the same
  /// project at once can step on each other's generated files.
  Map<String, Future<String>> _buildApps(Set<String> platforms) {
    var builds = <String, Future<String>>{};
    Future<void> previous = Future.value();
    for (var platform in platforms) {
      var build = previous.then((_) => _buildApp(platform));
      builds[platform] = build;
      previous = build.then((_) {}, onError: (_) {});
    }
    return builds;
  }

  Future<String> _buildApp(String platform) async {
    var isIos = platform == CaptureConfig.platformIos;
    var log = File("$_workDir/logs/build-$platform.log");
    print("Building the $platform app (log: ${log.path})...");

    var output = "";
    try {
      output = await host.run(
        "flutter",
        [
          "build",
          ...isIos ? ["ios", "--simulator"] : ["apk"],
          "--debug",
          "-t",
          config.entrypoint,
          ...config.flutterArgs,
        ],
        workingDirectory: config.appDir,
        timeout: _buildTimeout,
      );
    } on Exception catch (e) {
      log.writeAsStringSync("$e");
      throw Exception("$platform build failed; see ${log.path}");
    }
    log.writeAsStringSync(output);

    var built = RegExp(
      isIos ? r"Built (\S+\.app)" : r"Built (\S+\.apk)",
    ).firstMatch(output)?.group(1);
    if (built == null) {
      throw Exception("Couldn't find the built $platform app in ${log.path}");
    }
    print("Built the $platform app.");
    return File("${config.appDir}/$built").absolute.path;
  }

  /// Runs [binary] for one locale, answering its handshake, and writes the
  /// captured PNGs to [outDir]. Retries if `flutter run` can't see the
  /// device yet.
  Future<void> _captureLocale(
    Device device,
    String locale,
    List<Map<String, dynamic>> captures,
    String? seedBundle,
    String binary,
    String outDir,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await _runLocale(device, locale, captures, seedBundle, binary, outDir);
        return;
      } on _DeviceNotFoundException {
        if (attempt >= _maxLaunchAttempts) {
          rethrow;
        }
        print("[${device.name}] flutter can't see the device yet; retrying");
        await Future.delayed(_launchRetryDelay);
      }
    }
  }

  Future<void> _runLocale(
    Device device,
    String locale,
    List<Map<String, dynamic>> captures,
    String? seedBundle,
    String binary,
    String outDir,
  ) async {
    // Start clean so only this run's captures are published.
    var out = Directory(outDir);
    if (out.existsSync()) {
      out.deleteSync(recursive: true);
    }
    out.createSync(recursive: true);
    var logFile = File("$_workDir/logs/${device.name}-$locale.log");
    var log = logFile.openWrite();

    print("[${device.name}] $locale: launching (log: ${logFile.path})");
    var process = await Process.start("flutter", [
      "run",
      "--use-application-binary",
      binary,
      "-t",
      config.entrypoint,
      "-d",
      device.id,
      "--no-pub",
      ...config.flutterArgs,
    ], workingDirectory: config.appDir);
    // Writing to stdin after flutter exits fails asynchronously; ignore it.
    process.stdin.done.ignore();
    var stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(log.writeln);

    var captured = <String>{};
    var isReady = false;
    var isDone = false;
    String? failure;
    var isQuitting = false;
    var isDeviceMissing = false;
    var quitTimers = <Timer>[];

    void quit() {
      if (isQuitting) {
        return;
      }
      isQuitting = true;
      try {
        process.stdin.writeln("q");
      } on Object {
        // flutter already exited.
      }
      quitTimers = [
        Timer(_quitTimeout, process.kill),
        Timer(_quitTimeout * 2, () => process.kill(ProcessSignal.sigkill)),
      ];
    }

    Timer startSilenceTimer() => Timer(_silenceTimeout, () {
      failure = "no response from the app for ${_silenceTimeout.inMinutes}m";
      quit();
    });
    var silence = startSilenceTimer();

    try {
      await for (var line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        log.writeln(line);
        if (line.contains(_deviceNotFound)) {
          isDeviceMissing = true;
        }
        var index = line.indexOf(marker);
        if (index == -1 || isQuitting) {
          continue;
        }

        silence.cancel();
        silence = startSilenceTimer();

        var message = line.substring(index + marker.length).trim();
        var command = message.split(" ").first;
        var argument = message.substring(command.length).trim();

        switch (command) {
          case commandReady:
            // Device logs occasionally repeat lines; only answer once.
            if (isReady) {
              continue;
            }
            isReady = true;
            await device.onAppReady(argument, {
              "locale": config.locales[locale],
              "captures": captures,
              "isSeeded": seedBundle != null,
            }, seedBundle);
          case commandCapture:
            if (captured.contains(argument)) {
              continue;
            }
            var path = "$outDir/$argument.png";
            await device.beforeScreenshot();
            await device.screenshot(path);
            device.verifyOrientation(path);
            captured.add(argument);
            print("[${device.name}] $locale: captured $argument");
            await device.ack(argument);
          case commandDone:
            isDone = true;
            quit();
          case commandFailed:
            failure = argument;
            quit();
          case commandLog:
            print("[${device.name}] $argument");
          default:
            print("[${device.name}] $message");
        }
      }
    } finally {
      // Covers errors thrown while handling a line, which would otherwise
      // leave flutter running and this waiting forever.
      quit();
      silence.cancel();
      await stderrDone;
      await process.exitCode;
      for (var timer in quitTimers) {
        timer.cancel();
      }
      await log.flush();
      await log.close();
    }

    if (!isDone && isDeviceMissing) {
      throw _DeviceNotFoundException(device.id, logFile.path);
    }
    if (!isDone) {
      throw Exception(
        "$locale run failed (${failure ?? "flutter run exited early"}; "
        "captured ${captured.length}/${captures.length}); see "
        "${logFile.path}",
      );
    }
  }

  /// Copies captured screenshots into the studio's assets.
  void _publish(Map<String, dynamic> spec, String outDir) {
    for (var locale in locales) {
      var source = Directory("$outDir/$locale");
      if (!source.existsSync()) {
        continue;
      }
      var target = Directory("${config.assetsDir}/${spec["output"]}/$locale")
        ..createSync(recursive: true);
      var files = source.listSync().whereType<File>().toList();
      for (var file in files) {
        file.copySync("${target.path}/${file.uri.pathSegments.last}");
      }
      print("Published ${files.length} screenshots to ${target.path}");
    }
  }

  /// The contents of [_xcodeTargetFiles] that exist, by path.
  Map<String, String> _backUpXcodeTargetFiles() => {
    for (var path in _xcodeTargetFiles)
      if (File("${config.appDir}/$path").existsSync())
        path: File("${config.appDir}/$path").readAsStringSync(),
  };

  void _restoreXcodeTargetFiles(Map<String, String> backup) {
    for (var MapEntry(key: path, value: contents) in backup.entries) {
      File("${config.appDir}/$path").writeAsStringSync(contents);
    }
  }
}

class _DeviceNotFoundException implements Exception {
  final String deviceId;
  final String logPath;

  _DeviceNotFoundException(this.deviceId, this.logPath);

  @override
  String toString() => "flutter run couldn't find $deviceId; see $logPath";
}
