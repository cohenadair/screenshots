import 'package:flutter_test/flutter_test.dart';
import 'package:screenshots_capture/src/host/options.dart';

void main() {
  test("parse with only a project uses defaults", () {
    var options = CaptureOptions.parse(["anglers-log"]);
    expect(options.project, "anglers-log");
    expect(options.devices, isNull);
    expect(options.locales, isNull);
    expect(options.only, isNull);
    expect(options.keepRunning, isFalse);
    expect(options.seedArgs, isEmpty);
  });

  test("parse reads every option", () {
    var options = CaptureOptions.parse([
      "anglers-log",
      "--devices",
      "iphone, ipad",
      "--locales",
      "es",
      "--only",
      "01,04",
      "--keep-running",
    ]);
    expect(options.devices, ["iphone", "ipad"]);
    expect(options.locales, ["es"]);
    expect(options.only, ["01", "04"]);
    expect(options.keepRunning, isTrue);
  });

  test("parse passes arguments after -- to the seed command", () {
    var options = CaptureOptions.parse([
      "anglers-log",
      "--only",
      "01",
      "--",
      "--placeholder-photos",
    ]);
    expect(options.only, ["01"]);
    expect(options.seedArgs, ["--placeholder-photos"]);
  });

  test("parse throws without a project", () {
    expect(() => CaptureOptions.parse([]), throwsArgumentError);
  });

  test("parse throws when the first argument is an option", () {
    expect(() => CaptureOptions.parse(["--only", "01"]), throwsArgumentError);
  });

  test("parse throws on an unknown option", () {
    expect(
      () => CaptureOptions.parse(["anglers-log", "--device", "iphone"]),
      throwsArgumentError,
    );
  });

  test("parse throws when a list option is last", () {
    expect(
      () => CaptureOptions.parse(["anglers-log", "--only"]),
      throwsArgumentError,
    );
  });

  test("parse throws when a list option is followed by another option", () {
    expect(
      () => CaptureOptions.parse(["anglers-log", "--only", "--keep-running"]),
      throwsArgumentError,
    );
  });
}
