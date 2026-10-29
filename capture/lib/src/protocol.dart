/// The handshake between the host (`bin/capture.dart`) and the app
/// ([runCaptures]), shared by both sides. Every line the app prints for the
/// host starts with [marker].
///
/// 1. The app prints `READY <dir>`, where `<dir>` is an empty directory in
///    its documents folder. The host copies the plan ([planFile]) and the
///    seed bundle ([seedDir]) into it, then creates [readyFile].
/// 2. The app seeds itself from the bundle and launches.
/// 3. For each capture in the plan, the app shows the screen, prints
///    `CAPTURE <name>`, and waits for the host to take the screenshot and
///    create [ackFile].
/// 4. The app prints `DONE`, or `FAILED <error>` if anything goes wrong.
///
/// The app may also print `LOG <message>`, which the host echoes.
library;

const marker = "SCREENSHOTS_CAPTURE:";

const commandReady = "READY";
const commandCapture = "CAPTURE";
const commandDone = "DONE";
const commandFailed = "FAILED";
const commandLog = "LOG";

/// The handshake directory's name, in the app's documents folder.
const handshakeDirName = "screenshots-capture";

const readyFile = "ready";
const planFile = "plan.json";
const seedDir = "seed";

String ackFile(String name) => "ack-$name";
