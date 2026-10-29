import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenshots_capture/seed.dart';
import 'package:screenshots_capture/src/host/process.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync("seed_test"));

  tearDown(() => tempDir.deleteSync(recursive: true));

  // Noon in Toronto (EDT, UTC-4).
  final noon = DateTime.utc(2026, 10, 29, 16);
  const toronto = "America/Toronto";

  // A 2x1 PNG.
  List<int> png() => base64Decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwH4QBEfcD"
    "/ePF9e8AAAAASUVORK5CYII=",
  );

  void writeTranslations(String locale, Map<String, String> strings) =>
      File("${tempDir.path}/translations/$locale.json")
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(strings));

  test("seedUuid is stable for a key", () {
    expect(
      seedUuid("walleye", namespace: "app"),
      seedUuid("walleye", namespace: "app"),
    );
  });

  test("seedUuid differs between namespaces", () {
    expect(
      seedUuid("walleye", namespace: "app"),
      isNot(seedUuid("walleye", namespace: "other")),
    );
  });

  test("SeedClock defaults now to the current time", () {
    var before = DateTime.now().millisecondsSinceEpoch;
    var now = SeedClock(toronto).timestamp("now");
    expect(now, greaterThanOrEqualTo(before));
    expect(now, lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch));
  });

  test("timestamp converts now", () {
    expect(
      SeedClock(toronto, now: noon).timestamp("now"),
      noon.millisecondsSinceEpoch,
    );
  });

  test("timestamp converts a relative time in the seed's time zone", () {
    var clock = SeedClock(toronto, now: noon);
    expect(
      clock.timestamp("-3d 06:42"),
      tz.TZDateTime(clock.zone, 2026, 10, 26, 6, 42).millisecondsSinceEpoch,
    );
  });

  test("timestamp reads an ISO date without an offset in the seed's zone", () {
    expect(
      SeedClock(toronto, now: noon).timestamp("2026-07-01T08:00:00"),
      DateTime.utc(2026, 7, 1, 12).millisecondsSinceEpoch,
    );
  });

  test("timestamp reads an ISO date with an offset as is", () {
    expect(
      SeedClock(toronto, now: noon).timestamp("2026-07-01T08:00:00Z"),
      DateTime.utc(2026, 7, 1, 8).millisecondsSinceEpoch,
    );
  });

  test("timestamp throws for an unknown format", () {
    expect(
      () => SeedClock(toronto, now: noon).timestamp("yesterday"),
      throwsFormatException,
    );
  });

  test("SeedTranslations for the base locale translates nothing", () {
    var translations = SeedTranslations.load(
      tempDir.path,
      "en",
      baseLocale: "en",
    );
    expect(translations.translate("Walleye"), "Walleye");
    expect(translations.missing(["Walleye"]), isEmpty);
  });

  test("SeedTranslations translates from its file", () {
    writeTranslations("es", {"Walleye": "Lucioperca"});
    var translations = SeedTranslations.load(
      tempDir.path,
      "es",
      baseLocale: "en",
    );
    expect(translations.translate("Walleye"), "Lucioperca");
    expect(translations.translate("Pike"), "Pike");
  });

  test("missing lists strings without a translation", () {
    writeTranslations("es", {});
    expect(
      SeedTranslations.load(
        tempDir.path,
        "es",
        baseLocale: "en",
      ).missing(["Walleye"]),
      ["Walleye"],
    );
  });

  test("SeedTranslations throws without a translation file", () {
    expect(
      () => SeedTranslations.load(tempDir.path, "fr", baseLocale: "en"),
      throwsException,
    );
  });

  test("locales lists the base locale and translation files", () {
    writeTranslations("es", {});
    expect(SeedTranslations.locales(tempDir.path, baseLocale: "en"), [
      "en",
      "es",
    ]);
  });

  test("locales is only the base locale without translations", () {
    expect(SeedTranslations.locales(tempDir.path, baseLocale: "en"), ["en"]);
  });

  test("visitJsonFields visits nested maps and lists", () {
    var keys = <String>[];
    visitJsonFields({
      "a": [
        {"b": 1},
      ],
      "c": {"d": 2},
    }, (key, _) => keys.add(key));
    expect(keys, ["a", "b", "c", "d"]);
  });

  test("collectStrings collects distinct strings of the given fields", () {
    expect(
      collectStrings(
        [
          {"name": "Walleye", "notes": 1},
          {
            "name": "Walleye",
            "nested": {"notes": "Big"},
          },
        ],
        {"name", "notes"},
      ),
      {"Walleye", "Big"},
    );
  });

  test("find returns a photo with an uppercase extension", () {
    File("${tempDir.path}/catch.PNG").writeAsBytesSync(png());
    expect(SeedPhotos(tempDir.path).find("catch")?.existsSync(), isTrue);
  });

  test("find returns null for a missing photo", () {
    expect(SeedPhotos(tempDir.path).find("catch"), isNull);
  });

  test("missing lists photos that don't exist", () {
    File("${tempDir.path}/a.jpg").writeAsBytesSync([0]);
    expect(SeedPhotos(tempDir.path).missing(["a", "b"]).single, contains("b"));
  });

  test("writeJpeg copies a JPEG as is", () async {
    File("${tempDir.path}/a.jpeg").writeAsBytesSync([1, 2, 3]);
    var target = "${tempDir.path}/out.jpg";
    await SeedPhotos(
      tempDir.path,
    ).writeJpeg("a", target, usesPlaceholder: false);
    expect(File(target).readAsBytesSync(), [1, 2, 3]);
  });

  test("writeJpeg converts other formats with sips", () async {
    File("${tempDir.path}/a.png").writeAsBytesSync(png());
    var target = "${tempDir.path}/out.jpg";
    await SeedPhotos(
      tempDir.path,
    ).writeJpeg("a", target, usesPlaceholder: false);
    expect(await run("file", ["-b", target]), startsWith("JPEG"));
  });

  test("writeJpeg writes a placeholder for a missing photo", () async {
    var target = "${tempDir.path}/out.jpg";
    await SeedPhotos(
      tempDir.path,
    ).writeJpeg("a", target, usesPlaceholder: true);
    expect(await run("file", ["-b", target]), startsWith("JPEG"));
  });

  test("writeJpeg throws for a missing photo without placeholders", () {
    expect(
      SeedPhotos(
        tempDir.path,
      ).writeJpeg("a", "${tempDir.path}/out.jpg", usesPlaceholder: false),
      throwsException,
    );
  });

  test("pubspecVersion drops the build number", () {
    var file = File("${tempDir.path}/pubspec.yaml")
      ..writeAsStringSync("name: app\nversion: 2.8.1+123\n");
    expect(pubspecVersion(file.path), "2.8.1");
  });

  test("SeedOptions.parse reads every option", () {
    var options = SeedOptions.parse([
      "--locale",
      "es",
      "--out",
      "/tmp/out",
      "--placeholder-photos",
    ], baseLocale: "en");
    expect(options.isCheck, isFalse);
    expect(options.locale, "es");
    expect(options.outDir, "/tmp/out");
    expect(options.usesPlaceholderPhotos, isTrue);
  });

  test("SeedOptions.parse defaults to the base locale", () {
    var options = SeedOptions.parse(["--check"], baseLocale: "en");
    expect(options.isCheck, isTrue);
    expect(options.locale, "en");
    expect(options.outDir, isNull);
  });

  test("SeedOptions.parse throws without --out or --check", () {
    expect(() => SeedOptions.parse([], baseLocale: "en"), throwsArgumentError);
  });

  test("SeedOptions.parse throws on an unknown option", () {
    expect(
      () => SeedOptions.parse(["--check", "--bogus"], baseLocale: "en"),
      throwsArgumentError,
    );
  });

  test("SeedOptions.parse throws when an option is missing its value", () {
    expect(
      () => SeedOptions.parse(["--out"], baseLocale: "en"),
      throwsArgumentError,
    );
  });
}
