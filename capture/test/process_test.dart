import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenshots_capture/src/host/process.dart';

void main() {
  // A 2x1 PNG.
  Uint8List png() => base64Decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwH4QBEfcD"
    "/ePF9e8AAAAASUVORK5CYII=",
  );

  test("pngSize reads the width and height", () {
    expect(pngSize(png()), (2, 1));
  });

  test("pngSize throws for data that's too short", () {
    expect(() => pngSize(Uint8List(8)), throwsException);
  });

  test("pngSize throws for data that isn't a PNG", () {
    expect(
      () => pngSize(Uint8List.fromList(List.filled(32, 1))),
      throwsException,
    );
  });

  test("run returns trimmed stdout", () async {
    expect(await run("echo", ["hello"]), "hello");
  });

  test("run throws when the command fails", () async {
    expect(run("false", []), throwsException);
  });

  test("run returns output when failure is allowed", () async {
    expect(await run("false", [], allowFailure: true), "");
  });

  test("run uses the working directory and environment", () async {
    expect(
      await run(
        "sh",
        ["-c", r"echo $VALUE; pwd"],
        workingDirectory: "/",
        environment: {"VALUE": "set"},
      ),
      "set\n/",
    );
  });

  test("run throws when the command times out", () async {
    expect(
      run("sleep", ["5"], timeout: const Duration(milliseconds: 100)),
      throwsException,
    );
  });

  test("runBytes returns stdout as bytes", () async {
    expect(await runBytes("printf", ["ab"]), [97, 98]);
  });

  test("runBytes throws when the command fails", () async {
    expect(runBytes("false", []), throwsException);
  });
}
