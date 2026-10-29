/// Captures a project's App Store / Google Play screenshots on iOS
/// simulators and Android emulators, and publishes them to its studio assets.
/// See README.md.
///
/// Usage, from this directory:
///   dart run bin/capture.dart <project> [options] [-- <seed args>]
///
/// <project> is an id from projects.json, a path to a capture.json, or a
/// directory containing one.
///
/// Options:
///   --devices iphone,ipad,...  Devices from capture.json (default: all).
///   --locales en,es            Locales from capture.json (default: all).
///   --only 01,04               Capture only these file names.
///   --keep-running             Don't shut down devices this run booted.
///
/// Arguments after `--` are passed to the project's seed command.
library;

import 'dart:io';

import 'package:screenshots_capture/src/host/config.dart';
import 'package:screenshots_capture/src/host/options.dart';
import 'package:screenshots_capture/src/host/runner.dart';

// ignore_for_file: avoid_print

/// sysexits.h's EX_USAGE.
const _exitUsage = 64;

Future<void> main(List<String> args) async {
  try {
    var options = CaptureOptions.parse(args);
    var config = CaptureConfig.load(
      options.project,
      File.fromUri(Platform.script).parent.parent.path,
    );
    exit(
      await Runner(
            config: config,
            devices: options.devices ?? config.devices.keys.toList(),
            locales: options.locales ?? config.locales.keys.toList(),
            only: options.only,
            keepRunning: options.keepRunning,
            seedArgs: options.seedArgs,
          ).run()
          ? 0
          : 1,
    );
  } on ArgumentError catch (e) {
    print(e.message);
    exit(_exitUsage);
  }
}
