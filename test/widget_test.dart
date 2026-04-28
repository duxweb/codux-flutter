import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codux_flutter/main.dart';
import 'package:codux_flutter/i18n.dart';

void main() {
  testWidgets('Codux app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const CoduxFlutterApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  test('mobile languages match Mac language count', () {
    expect(LocaleChoices.all.length, 11);
    expect(LocaleChoices.byId('zh-CN').id, 'simplifiedChinese');
    expect(LocaleChoices.byId('en-US').id, 'english');
    expect(tr('settings.title', 'traditionalChinese'), '設定');
    expect(tr('settings.title', 'japanese'), '設定');
  });
}
