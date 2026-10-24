import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/mobile/menu/bottom_navigation.dart';
import 'package:proxypin/ui/toolbox/toolbox.dart';

Widget classicPage(WidgetBuilder builder) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: builder)),
    );

void main() {
  testWidgets('Android uses a lightweight classic card and divider', (tester) async {
    await tester.pumpWidget(classicPage((context) => menuCard(context, [menuDivider(context)])));
    await tester.pumpAndSettle();
    final card = tester.widget<Card>(find.byType(Card));
    final shape = card.shape! as RoundedRectangleBorder;
    final divider = tester.widget<Divider>(find.byType(Divider));
    expect(card.color, Colors.transparent);
    expect(card.clipBehavior, Clip.none);
    expect(shape.side.color.a, closeTo(0.13 * Theme.of(tester.element(find.byType(Card))).dividerColor.a, 0.01));
    expect(divider.indent, 0);
    expect(divider.thickness, 0.3);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android keeps menu actions and status summaries with Material icons', (tester) async {
    var opened = false;
    await tester.pumpWidget(classicPage((context) => menuTile(context, 'lines', 'Hosts', () async {
          opened = true;
        }, iconColor: Colors.blue, status: 'Enabled · 3 rules', statusOn: true)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.domain), findsOneWidget);
    expect(find.byType(SvgIcon), findsNothing);
    expect(find.text('Enabled · 3 rules'), findsOneWidget);
    await tester.tap(find.text('Hosts'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android settings rows omit decorative leading blocks', (tester) async {
    await tester.pumpWidget(classicPage((context) =>
        menuTile(context, 'lock', 'HTTPS capture', () async {}, iconColor: Colors.blue, showAndroidIcon: false)));
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.leading, isNull);
    expect(find.text('HTTPS capture'), findsOneWidget);
    expect(find.byType(SvgIcon), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android classic toolbox keeps all seventeen tool actions on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(classicPage((context) => const Toolbox()));
    await tester.pumpAndSettle();
    final tools = tester.widgetList<IconText>(find.byType(IconText)).toList();
    expect(tools.length, 17);
    expect(tools.every((tool) => tool.onTap != null), isTrue);
    expect(tools.map((tool) => tool.text),
        containsAll(['HTTP', 'WebSocket', 'JavaScript', 'JSON', 'XML', 'URL', 'Base64', 'Unicode', 'MD5', 'AES']));
    final iconText = tester.element(find.byType(IconText).first);
    final blocks = find.descendant(of: find.byWidget(iconText.widget), matching: find.byType(Container));
    expect(blocks, findsOneWidget);
    expect(tester.widget<Container>(blocks).decoration, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
