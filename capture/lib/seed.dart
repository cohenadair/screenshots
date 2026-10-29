/// Host-side helpers for a project's seed command (the `seed.command` in its
/// `capture.json`), which turns the project's seed data into a bundle its
/// `CaptureApp` can load. Pure Dart, so it can be run with `dart run`.
///
/// A seed folder conventionally holds:
///   - the seed data itself, in whatever shape the project uses;
///   - `translations/<locale>.json`: base-locale string → translation;
///   - `photos/`: images referenced by file name without extension.
library;

import 'dart:convert';
import 'dart:io';

import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'src/host/process.dart';

// ignore_for_file: avoid_print

/// sysexits.h's EX_USAGE.
const _exitUsage = 64;
const _exitProblems = 1;

const _optionCheck = "--check";
const _optionLocale = "--locale";
const _optionOut = "--out";
const _optionPlaceholderPhotos = "--placeholder-photos";

/// The deterministic UUID (v5) for a seed [key], so entities can refer to
/// each other by key and keep the same ID across runs. [namespace] keeps
/// different projects' IDs apart.
String seedUuid(String key, {required String namespace}) =>
    const Uuid().v5(Namespace.url.value, "$namespace:$key");

/// Converts seed timestamps into epoch milliseconds, in the seed's time
/// zone, relative to one moment so a whole bundle is consistent.
class SeedClock {
  static final _relative = RegExp(r"^(-?\d+)d (\d{1,2}):(\d{2})$");
  static var _isTimeZoneDataLoaded = false;

  final tz.Location zone;
  final tz.TZDateTime now;

  SeedClock._(this.zone, this.now);

  /// [timeZone] is an IANA name such as "America/Toronto". [now] defaults to
  /// the current time.
  factory SeedClock(String timeZone, {DateTime? now}) {
    if (!_isTimeZoneDataLoaded) {
      tz_data.initializeTimeZones();
      _isTimeZoneDataLoaded = true;
    }
    var zone = tz.getLocation(timeZone);
    return SeedClock._(
      zone,
      now == null ? tz.TZDateTime.now(zone) : tz.TZDateTime.from(now, zone),
    );
  }

  /// Converts:
  ///   - "now";
  ///   - "-3d 06:42": 6:42 AM three days ago ("0d 05:30" is today), so seed
  ///     data never goes stale;
  ///   - an ISO-8601 date, read in [zone] unless it has an offset.
  int timestamp(String value) {
    if (value == "now") {
      return now.millisecondsSinceEpoch;
    }

    var match = _relative.firstMatch(value);
    if (match == null) {
      return tz.TZDateTime.parse(zone, value).millisecondsSinceEpoch;
    }

    return tz.TZDateTime(
      zone,
      now.year,
      now.month,
      now.day + int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ).millisecondsSinceEpoch;
  }
}

/// A seed's `translations/<locale>.json` files, which map each user-visible
/// base-locale string to its translation.
class SeedTranslations {
  final String locale;
  final bool _isBase;
  final Map<String, String> _strings;

  SeedTranslations._(this.locale, this._strings, {bool isBase = false})
    : _isBase = isBase;

  /// An empty set for [baseLocale], which needs no translation.
  factory SeedTranslations.load(
    String seedDir,
    String locale, {
    required String baseLocale,
  }) {
    if (locale == baseLocale) {
      return SeedTranslations._(locale, const {}, isBase: true);
    }
    var file = File("$seedDir/translations/$locale.json");
    if (!file.existsSync()) {
      throw Exception("No translation file: ${file.path}");
    }
    return SeedTranslations._(
      locale,
      (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
          .cast<String, String>(),
    );
  }

  /// [baseLocale] plus every locale with a translation file.
  static List<String> locales(String seedDir, {required String baseLocale}) => [
    baseLocale,
    for (var file
        in Directory("$seedDir/translations").existsSync()
            ? Directory("$seedDir/translations").listSync().whereType<File>()
            : const <File>[])
      if (file.path.endsWith(".json"))
        file.uri.pathSegments.last.replaceAll(".json", ""),
  ];

  /// [text] in this locale, or [text] itself if it has no translation.
  String translate(String text) => _strings[text] ?? text;

  /// The strings in [texts] with no translation; always empty for the base
  /// locale.
  List<String> missing(Iterable<String> texts) => _isBase
      ? const []
      : texts.where((e) => !_strings.containsKey(e)).toList();
}

/// Calls [visit] for every key/value pair in [json], recursing into maps and
/// lists, e.g. to collect the strings that need translating.
void visitJsonFields(
  Object? json,
  void Function(String key, Object? value) visit,
) {
  if (json is Map<String, dynamic>) {
    json.forEach((key, value) {
      visit(key, value);
      visitJsonFields(value, visit);
    });
  } else if (json is List) {
    for (var item in json) {
      visitJsonFields(item, visit);
    }
  }
}

/// The distinct string values of [fields] anywhere in [json], in order.
Set<String> collectStrings(Object? json, Set<String> fields) {
  var result = <String>{};
  visitJsonFields(json, (key, value) {
    if (fields.contains(key) && value is String) {
      result.add(value);
    }
  });
  return result;
}

/// A seed's `photos/` folder. Photos are referred to by file name without
/// extension, and written to the bundle as JPEGs.
class SeedPhotos {
  static const extensions = ["jpg", "jpeg", "png", "heic", "webp"];
  static const _jpegExtensions = {"jpg", "jpeg"};

  static const _placeholderSize = "1600x1200";
  static const _placeholderPointSize = 72;

  final String dir;

  /// The placeholder background, as ImageMagick colors, top to bottom.
  final (String, String) placeholderGradient;

  SeedPhotos(this.dir, {this.placeholderGradient = ("#4A5A6A", "#1C2530")});

  /// The photo named [stem] with any of [extensions], in either case.
  File? find(String stem) {
    for (var ext in extensions) {
      for (var candidate in [ext, ext.toUpperCase()]) {
        var file = File("$dir/$stem.$candidate");
        if (file.existsSync()) {
          return file;
        }
      }
    }
    return null;
  }

  /// Writes photo [stem] to [target] as a JPEG, converting it with `sips` if
  /// needed. If it's missing, writes a labeled placeholder (with ImageMagick)
  /// if [usesPlaceholder], and throws otherwise.
  Future<void> writeJpeg(
    String stem,
    String target, {
    required bool usesPlaceholder,
  }) async {
    var source = find(stem);
    if (source == null) {
      if (!usesPlaceholder) {
        throw Exception(
          "Missing photo $dir/$stem.* (use $_optionPlaceholderPhotos to "
          "generate stand-ins)",
        );
      }
      await run("magick", [
        "-size",
        _placeholderSize,
        "gradient:${placeholderGradient.$1}-${placeholderGradient.$2}",
        "-gravity",
        "center",
        "-fill",
        "white",
        "-pointsize",
        "$_placeholderPointSize",
        "-annotate",
        "0",
        stem,
        target,
      ]);
    } else if (_jpegExtensions.contains(
      source.path.split(".").last.toLowerCase(),
    )) {
      source.copySync(target);
    } else {
      await run("sips", ["-s", "format", "jpeg", source.path, "--out", target]);
    }
  }

  /// A problem for each of [stems] that has no photo.
  List<String> missing(Iterable<String> stems) => [
    for (var stem in stems)
      if (find(stem) == null)
        "Missing photo: $dir/$stem.{${extensions.join(",")}}",
  ];
}

/// The `version:` in the pubspec at [path], without the build number.
String pubspecVersion(String path) => File(path)
    .readAsLinesSync()
    .firstWhere((e) => e.startsWith("version:"))
    .split(":")[1]
    .trim()
    .split("+")
    .first;

/// The options a seed command takes; see [runSeedCli].
class SeedOptions {
  final bool isCheck;
  final String locale;
  final String? outDir;
  final bool usesPlaceholderPhotos;

  SeedOptions({
    required this.isCheck,
    required this.locale,
    required this.outDir,
    required this.usesPlaceholderPhotos,
  });

  /// Parses `--check`, `--locale <locale>`, `--out <dir>`, and
  /// `--placeholder-photos`. Throws [ArgumentError] on anything else, or if
  /// neither `--check` nor `--out` is given.
  factory SeedOptions.parse(List<String> args, {required String baseLocale}) {
    var isCheck = false;
    var usesPlaceholderPhotos = false;
    var values = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      var arg = args[i];
      if (arg == _optionCheck) {
        isCheck = true;
      } else if (arg == _optionPlaceholderPhotos) {
        usesPlaceholderPhotos = true;
      } else if (arg == _optionLocale || arg == _optionOut) {
        if (i + 1 >= args.length) {
          throw ArgumentError("$arg needs a value");
        }
        values[arg] = args[++i];
      } else {
        throw ArgumentError("Unknown option \"$arg\"");
      }
    }
    if (!isCheck && values[_optionOut] == null) {
      throw ArgumentError("Missing $_optionOut <dir> (or pass $_optionCheck)");
    }
    return SeedOptions(
      isCheck: isCheck,
      locale: values[_optionLocale] ?? baseLocale,
      outDir: values[_optionOut],
      usesPlaceholderPhotos: usesPlaceholderPhotos,
    );
  }
}

/// The `main` of a seed command. With `--check`, prints [check]'s problems
/// and exits 1 if there are any. Otherwise calls [build] to write the bundle
/// for `--locale` (default [baseLocale]) to `--out`.
Future<void> runSeedCli(
  List<String> args, {
  required String baseLocale,
  required List<String> Function() check,
  required Future<void> Function(SeedOptions options) build,
}) async {
  SeedOptions options;
  try {
    options = SeedOptions.parse(args, baseLocale: baseLocale);
  } on ArgumentError catch (e) {
    print(
      "${e.message}\nUsage: [$_optionCheck] [$_optionLocale <locale>] "
      "[$_optionOut <dir>] [$_optionPlaceholderPhotos]",
    );
    exit(_exitUsage);
  }

  if (options.isCheck) {
    var problems = check();
    if (problems.isEmpty) {
      print("Seed OK.");
      return;
    }
    problems.forEach(print);
    exit(_exitProblems);
  }

  var out = Directory(options.outDir!);
  if (out.existsSync()) {
    out.deleteSync(recursive: true);
  }
  out.createSync(recursive: true);
  await build(options);
  print("Wrote ${options.locale} seed bundle to ${out.path}");
}
