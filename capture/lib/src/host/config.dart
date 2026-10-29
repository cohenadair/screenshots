import 'dart:convert';
import 'dart:io';

/// A project's `capture.json`. Paths in it are relative to its directory.
class CaptureConfig {
  static const platformIos = "ios";
  static const platformAndroid = "android";

  /// Permissions `capture.json` can ask to have granted before the app
  /// launches.
  static const permissionLocation = "location";
  static const permissionNotifications = "notifications";
  static const permissionPhotos = "photos";
  static const knownPermissions = {
    permissionLocation,
    permissionNotifications,
    permissionPhotos,
  };

  final String path;
  final Map<String, dynamic> _json;

  CaptureConfig(this.path, this._json);

  /// Loads [project]: an id from this tool's `projects.json`, a path to a
  /// `capture.json`, or a directory containing one.
  factory CaptureConfig.load(String project, String toolDir) {
    var path = _findConfig(project, toolDir);
    return CaptureConfig(
      path,
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
    );
  }

  String get dir => File(path).parent.path;

  /// The Flutter app's root directory, where `flutter` commands run.
  String get appDir => resolve(_json["app"] as String);

  /// The app-side entrypoint, which calls `runCaptures`.
  String get entrypoint => resolve(_json["entrypoint"] as String);

  /// The studio's asset folder for this project.
  String get assetsDir => resolve(_json["assets"] as String);

  /// The studio's slide deck.
  String get deckPath => "$assetsDir/app-store-screenshots.json";

  /// Extra arguments for `flutter build` and `flutter run`, e.g. a flavor.
  List<String> get flutterArgs =>
      (_json["flutterArgs"] as List?)?.cast<String>() ?? const [];

  String? get iosBundleId =>
      (_json[platformIos] as Map<String, dynamic>?)?["bundleId"] as String?;

  String? get androidPackage =>
      (_json[platformAndroid] as Map<String, dynamic>?)?["package"] as String?;

  /// Where simulators and emulators are placed, as `[lat, lng]`, or null to
  /// leave them where they are.
  List<num>? get deviceLocation =>
      (_json["deviceLocation"] as List?)?.cast<num>();

  /// Permissions granted to the app before it launches; see
  /// [knownPermissions].
  List<String> get permissions =>
      (_json["permissions"] as List?)?.cast<String>() ?? const [];

  /// The seed command, run in [dir] once per locale, or null if the project
  /// doesn't seed.
  List<String>? get seedCommand =>
      ((_json["seed"] as Map<String, dynamic>?)?["command"] as List?)
          ?.cast<String>();

  /// Deck locale (e.g. "en") to the locale the app is launched in (e.g.
  /// "en_US").
  Map<String, String> get locales =>
      (_json["locales"] as Map<String, dynamic>).cast<String, String>();

  Map<String, dynamic> get devices => _json["devices"] as Map<String, dynamic>;

  Map<String, dynamic> get screens => _json["screens"] as Map<String, dynamic>;

  String platform(String device) =>
      (devices[device] as Map<String, dynamic>)["platform"] as String;

  /// File name (e.g. "01") to screen name, for [device].
  Map<String, String> captures(String device) =>
      ((_json["captures"] as Map<String, dynamic>)[device]
              as Map<String, dynamic>)
          .cast<String, String>();

  /// Problems that would stop a run, e.g. an unknown platform, or a
  /// platform's devices without its bundle ID or package.
  List<String> validate() {
    var problems = <String>[];
    for (var device in devices.keys) {
      var platform = this.platform(device);
      if (platform == platformIos) {
        if (iosBundleId == null) {
          problems.add("$device is iOS, but \"ios.bundleId\" isn't set");
        }
      } else if (platform == platformAndroid) {
        if (androidPackage == null) {
          problems.add("$device is Android, but \"android.package\" isn't set");
        }
      } else {
        problems.add("$device has unknown platform \"$platform\"");
      }
    }
    for (var permission in permissions) {
      if (!knownPermissions.contains(permission)) {
        problems.add("Unknown permission \"$permission\"");
      }
    }
    return problems;
  }

  String resolve(String relative) =>
      File("$dir/$relative").absolute.uri.normalizePath().toFilePath();

  static String _findConfig(String project, String toolDir) {
    var registry = File("$toolDir/projects.json");
    if (registry.existsSync()) {
      for (var entry
          in (jsonDecode(registry.readAsStringSync())["projects"] as List)
              .cast<Map<String, dynamic>>()) {
        if (entry["id"] == project) {
          return File(
            "$toolDir/${entry["config"]}",
          ).absolute.uri.normalizePath().toFilePath();
        }
      }
    }

    if (Directory(project).existsSync()) {
      return File("$project/capture.json").absolute.path;
    }
    if (File(project).existsSync()) {
      return File(project).absolute.path;
    }
    throw ArgumentError(
      "Unknown project \"$project\"; use an id from projects.json or a path "
      "to a capture.json",
    );
  }
}
