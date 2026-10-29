import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'process.dart';

/// A simulator or emulator, as described by an entry in `capture.json`'s
/// `devices`.
abstract class Device {
  static const orientationPortrait = "portrait";
  static const orientationLandscape = "landscape";

  /// The status bar shown in every screenshot.
  static const statusBarTime = "9:41";
  static const statusBarBatteryLevel = 100;
  static const statusBarSignalBars = 4;

  static const pollInterval = Duration(milliseconds: 250);

  final String name;
  final Map<String, dynamic> spec;
  final CaptureConfig config;

  /// Where screenshots and other working files go.
  final String workDir;

  /// True if this run booted the device (and should shut it down).
  var didBoot = false;

  String expectedOrientation = orientationPortrait;

  Device(this.name, this.spec, this.config, this.workDir);

  /// The ID passed to `flutter run -d`. Only valid after [boot].
  String get id;

  Future<void> boot();

  /// Sets a clean status bar, light appearance, and [location] if set.
  Future<void> prepare(List<num>? location);

  Future<void> ensureOrientation(String orientation);

  /// Called when the app prints READY: grants permissions, copies the seed
  /// bundle (if any) and [plan] to [dir] on the device, then signals the app
  /// to continue.
  Future<void> onAppReady(
    String dir,
    Map<String, dynamic> plan,
    String? seedBundle,
  );

  /// Clears anything the app can't control from the screen, such as system
  /// dialogs.
  Future<void> beforeScreenshot() => Future.value();

  Future<void> screenshot(String path);

  Future<void> ack(String name);

  /// Restores the device, or shuts it down if [shutDown] and this run booted
  /// it. Safe to call even if [boot] failed.
  Future<void> cleanUp({required bool shutDown});

  void verifyOrientation(String path) {
    var actual = orientationOf(path);
    if (actual != expectedOrientation) {
      throw Exception(
        "$name screenshot is $actual, but the deck expects "
        "$expectedOrientation",
      );
    }
  }

  String orientationOf(String path) {
    var (width, height) = pngSize(File(path).readAsBytesSync());
    return width > height ? orientationLandscape : orientationPortrait;
  }

  /// Polls [check] every [pollInterval] until it returns true, or throws
  /// with [message] after [timeout].
  Future<void> waitUntil(
    Future<bool> Function() check, {
    required Duration timeout,
    required String message,
  }) async {
    var end = DateTime.now().add(timeout);
    while (!await check()) {
      if (DateTime.now().isAfter(end)) {
        throw Exception(message);
      }
      await Future.delayed(pollInterval);
    }
  }
}
