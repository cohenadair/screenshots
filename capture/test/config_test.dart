import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenshots_capture/src/host/config.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync("config_test"));

  tearDown(() => tempDir.deleteSync(recursive: true));

  Map<String, dynamic> validJson() => {
    "app": "../app",
    "entrypoint": "capture_app.dart",
    "assets": "../assets",
    "ios": {"bundleId": "com.example.app"},
    "android": {"package": "com.example.app"},
    "locales": {"en": "en_US"},
    "devices": {
      "iphone": {"platform": "ios", "simulator": "iPhone 17 Pro"},
      "phone": {"platform": "android", "avd": "Phone"},
    },
    "screens": {
      "home": {"screen": "home"},
    },
    "captures": {
      "iphone": {"01": "home"},
      "phone": {"01": "home"},
    },
  };

  CaptureConfig config(Map<String, dynamic> json) =>
      CaptureConfig("${tempDir.path}/capture/capture.json", json);

  test("Paths resolve relative to the config file", () {
    var c = config(validJson());
    expect(c.dir, "${tempDir.path}/capture");
    expect(c.appDir, "${tempDir.path}/app");
    expect(c.entrypoint, "${tempDir.path}/capture/capture_app.dart");
    expect(c.deckPath, "${tempDir.path}/assets/app-store-screenshots.json");
  });

  test("Optional fields default when absent", () {
    var c = config(validJson());
    expect(c.deviceLocation, isNull);
    expect(c.permissions, isEmpty);
    expect(c.flutterArgs, isEmpty);
    expect(c.seedCommand, isNull);
  });

  test("Optional fields are read when present", () {
    var c = config({
      ...validJson(),
      "deviceLocation": [44.08, -81.42],
      "permissions": ["location"],
      "flutterArgs": ["--flavor", "prod"],
      "seed": {
        "command": ["dart", "run", "build_seed.dart"],
      },
    });
    expect(c.deviceLocation, [44.08, -81.42]);
    expect(c.permissions, ["location"]);
    expect(c.flutterArgs, ["--flavor", "prod"]);
    expect(c.seedCommand, ["dart", "run", "build_seed.dart"]);
  });

  test("platform and captures read a device's entries", () {
    var c = config(validJson());
    expect(c.platform("iphone"), CaptureConfig.platformIos);
    expect(c.captures("phone"), {"01": "home"});
  });

  test("validate passes a valid config", () {
    expect(config(validJson()).validate(), isEmpty);
  });

  test("validate requires the bundle ID for iOS devices", () {
    expect(
      config({...validJson(), "ios": null}).validate().single,
      contains("ios.bundleId"),
    );
  });

  test("validate requires the package for Android devices", () {
    expect(
      config({...validJson(), "android": null}).validate().single,
      contains("android.package"),
    );
  });

  test("validate rejects an unknown platform", () {
    var json = validJson()
      ..["devices"] = {
        "watch": {"platform": "watchos"},
      };
    expect(config(json).validate().single, contains("unknown platform"));
  });

  test("validate rejects an unknown permission", () {
    expect(
      config({
        ...validJson(),
        "permissions": ["camera"],
      }).validate().single,
      contains("Unknown permission"),
    );
  });

  test("load finds a project in projects.json", () {
    var configFile = File("${tempDir.path}/project/capture.json")
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(validJson()));
    File("${tempDir.path}/tool/projects.json")
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          "projects": [
            {"id": "app", "config": "../project/capture.json"},
          ],
        }),
      );
    expect(
      CaptureConfig.load("app", "${tempDir.path}/tool").path,
      configFile.absolute.path,
    );
  });

  test("load finds capture.json in a directory", () {
    File("${tempDir.path}/project/capture.json")
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(validJson()));
    expect(
      CaptureConfig.load("${tempDir.path}/project", tempDir.path).path,
      "${tempDir.path}/project/capture.json",
    );
  });

  test("load reads a config file path", () {
    var file = File("${tempDir.path}/my.json")
      ..writeAsStringSync(jsonEncode(validJson()));
    expect(CaptureConfig.load(file.path, tempDir.path).path, file.path);
  });

  test("load throws for an unknown project", () {
    expect(() => CaptureConfig.load("nope", tempDir.path), throwsArgumentError);
  });
}
