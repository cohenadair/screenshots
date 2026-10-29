import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Long enough for any single device command; builds pass their own.
const defaultCommandTimeout = Duration(minutes: 2);

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _pngWidthOffset = 16;
const _pngHeightOffset = 20;

/// Runs [executable] and returns its trimmed stdout, throwing if it fails
/// (unless [allowFailure]) or takes longer than [timeout].
Future<String> run(
  String executable,
  List<String> args, {
  bool allowFailure = false,
  String? workingDirectory,
  Map<String, String>? environment,
  Duration timeout = defaultCommandTimeout,
}) async {
  var (exitCode, stdout, stderr) = await _run(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    timeout: timeout,
    stdoutDecoder: (stream) => stream.transform(utf8.decoder).join(),
  );
  if (exitCode != 0 && !allowFailure) {
    throw Exception("$executable ${args.join(" ")} failed: $stderr".trim());
  }
  return stdout.trim();
}

/// Like [run], but returns stdout as bytes, for binary output such as
/// screenshots.
Future<Uint8List> runBytes(
  String executable,
  List<String> args, {
  Duration timeout = defaultCommandTimeout,
}) async {
  var (exitCode, stdout, stderr) = await _run(
    executable,
    args,
    timeout: timeout,
    stdoutDecoder: (stream) => stream
        .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
        .then((b) => b.takeBytes()),
  );
  if (exitCode != 0) {
    throw Exception("$executable ${args.join(" ")} failed: $stderr".trim());
  }
  return stdout;
}

/// A PNG's width and height, read from its header. Throws if [bytes] isn't a
/// PNG, e.g. when a screenshot command printed an error instead.
(int, int) pngSize(Uint8List bytes) {
  var isPng =
      bytes.length > _pngHeightOffset + 4 &&
      [
        for (var i = 0; i < _pngSignature.length; i++)
          bytes[i] == _pngSignature[i],
      ].every((e) => e);
  if (!isPng) {
    throw Exception("Not a PNG (${bytes.length} bytes)");
  }
  var data = ByteData.sublistView(bytes);
  return (data.getUint32(_pngWidthOffset), data.getUint32(_pngHeightOffset));
}

Future<(int, T, String)> _run<T>(
  String executable,
  List<String> args, {
  required Future<T> Function(Stream<List<int>>) stdoutDecoder,
  String? workingDirectory,
  Map<String, String>? environment,
  required Duration timeout,
}) async {
  var process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  var stdout = stdoutDecoder(process.stdout);
  var stderr = process.stderr.transform(utf8.decoder).join();
  try {
    var exitCode = await process.exitCode.timeout(timeout);
    return (exitCode, await stdout, await stderr);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw Exception(
      "$executable ${args.join(" ")} timed out after ${timeout.inSeconds}s",
    );
  }
}
