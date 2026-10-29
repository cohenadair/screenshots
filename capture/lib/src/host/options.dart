/// `bin/capture.dart`'s options; see its doc comment.
class CaptureOptions {
  static const devicesOption = "--devices";
  static const localesOption = "--locales";
  static const onlyOption = "--only";
  static const keepRunningFlag = "--keep-running";

  static const _listOptions = {devicesOption, localesOption, onlyOption};

  static const usage =
      "Usage: dart run bin/capture.dart <project> [$devicesOption a,b] "
      "[$localesOption a,b] [$onlyOption 01,02] [$keepRunningFlag] "
      "[-- <seed args>]";

  final String project;
  final List<String>? devices;
  final List<String>? locales;
  final List<String>? only;
  final bool keepRunning;

  /// Arguments after `--`, for the project's seed command.
  final List<String> seedArgs;

  CaptureOptions({
    required this.project,
    this.devices,
    this.locales,
    this.only,
    this.keepRunning = false,
    this.seedArgs = const [],
  });

  /// Throws [ArgumentError] with a message for the user on a missing
  /// project, an unknown option, or an option without its value.
  factory CaptureOptions.parse(List<String> args) {
    var separator = args.indexOf("--");
    var options = separator == -1 ? args : args.sublist(0, separator);
    if (options.isEmpty || options.first.startsWith("-")) {
      throw ArgumentError(usage);
    }

    var lists = <String, List<String>>{};
    var keepRunning = false;
    for (var i = 1; i < options.length; i++) {
      var option = options[i];
      if (option == keepRunningFlag) {
        keepRunning = true;
      } else if (_listOptions.contains(option)) {
        if (i + 1 >= options.length || options[i + 1].startsWith("-")) {
          throw ArgumentError("$option needs a value.\n$usage");
        }
        lists[option] = options[++i].split(",").map((e) => e.trim()).toList();
      } else {
        throw ArgumentError("Unknown option \"$option\".\n$usage");
      }
    }

    return CaptureOptions(
      project: options.first,
      devices: lists[devicesOption],
      locales: lists[localesOption],
      only: lists[onlyOption],
      keepRunning: keepRunning,
      seedArgs: separator == -1 ? const [] : args.sublist(separator + 1),
    );
  }
}
