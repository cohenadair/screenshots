import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshots_capture/screenshots_capture.dart';

void main() {
  test("parseLocale reads a language", () {
    expect(parseLocale("es"), const Locale("es"));
  });

  test("parseLocale reads a language and country", () {
    expect(parseLocale("en_US"), const Locale("en", "US"));
  });

  test("parseLocale reads a script and country", () {
    expect(
      parseLocale("zh_Hant_TW"),
      const Locale.fromSubtags(
        languageCode: "zh",
        scriptCode: "Hant",
        countryCode: "TW",
      ),
    );
  });
}
