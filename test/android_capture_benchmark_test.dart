import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/mobile/request/domians.dart';
import 'package:proxypin/ui/mobile/request/request.dart';
import 'package:proxypin/ui/mobile/request/request_sequence.dart';
import 'package:proxypin/utils/listenable_list.dart';

class CountingSearchModel extends SearchModel {
  int comparisons = 0;

  CountingSearchModel() : super('example');

  @override
  bool Function(String) buildMatcher() => (value) {
        comparisons++;
        return value.contains('example');
      };
}

Widget benchmarkPage(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

Future<ui.Image> decodeCachedImage(ImageProvider provider) async {
  final result = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, synchronous) => result.complete(info.image.clone()),
      onError: (Object error, StackTrace? stack) => result.completeError(error, stack));
  stream.addListener(listener);
  try {
    return await result.future;
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('display-sized Android icon decoding reduces actual Flutter image cache bytes', () async {
    final bytes = await File('assets/icon.png').readAsBytes();
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    final original = await decodeCachedImage(MemoryImage(bytes));
    final originalBytes = cache.currentSizeBytes;
    final originalWidth = original.width;
    cache.clear();
    cache.clearLiveImages();
    original.dispose();
    final resized = await decodeCachedImage(ResizeImage(MemoryImage(bytes), width: 120));
    final resizedBytes = cache.currentSizeBytes;
    expect(resized.width, 120);
    expect(resizedBytes, lessThan(originalBytes));
    print(jsonEncode({
      'metric': 'flutter_decoded_icon_cache_bytes',
      'source_width': originalWidth,
      'display_width': resized.width,
      'before': originalBytes,
      'after': resizedBytes,
      'reduction_percent': (1 - resizedBytes / originalBytes) * 100,
      'scope': 'one real PNG decode; not Android process RSS',
    }));
    resized.dispose();
    cache.clear();
    cache.clearLiveImages();
  });

  final domainComparisons = <TargetPlatform, int>{};
  testWidgets('batched Android domain updates avoid per-request full-list work', (tester) async {
    final key = GlobalKey<DomainListState>();
    final server = ProxyServer(Configuration.fromJson({}));
    await tester
        .pumpWidget(benchmarkPage(DomainList(key: key, list: ListenableList<HttpRequest>(), proxyServer: server)));
    await tester.pumpAndSettle();
    final matcher = CountingSearchModel();
    final state = key.currentState!;
    state.search(matcher);
    for (var index = 0; index < 2000; index++) {
      state.add(HttpRequest(HttpMethod.get, 'https://host$index.example/path')
        ..hostAndPort = HostAndPort.host('host$index.example', 443));
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.view.length, 2000);
    domainComparisons[defaultTargetPlatform] = matcher.comparisons;
    if (domainComparisons.length == 2) {
      final before = domainComparisons[TargetPlatform.linux]!;
      final after = domainComparisons[TargetPlatform.android]!;
      expect(after, 4000);
      expect(after, lessThan(before ~/ 100));
      print(jsonEncode({
        'metric': 'domain_filter_comparisons',
        'requests': 2000,
        'before': before,
        'after': after,
        'reduction_percent': (1 - after / before) * 100,
        'scope': 'original rendering path versus Android batched path; not device FPS',
      }));
    }
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.android}));

  final mountedRows = <TargetPlatform, int>{};
  testWidgets('Android mounts fewer offscreen rows during scrolling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = List.generate(2000, (index) => HttpRequest(HttpMethod.get, 'https://example.com/path/$index'));
    await tester.pumpWidget(benchmarkPage(RequestSequence(
      container: ListenableList(requests),
      proxyServer: ProxyServer(Configuration.fromJson({})),
      selectionController: MultiSelectController(),
    )));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -2500));
    await tester.pumpAndSettle();
    mountedRows[defaultTargetPlatform] = find.byType(RequestRow, skipOffstage: false).evaluate().length;
    if (mountedRows.length == 2) {
      final before = mountedRows[TargetPlatform.linux]!;
      final after = mountedRows[TargetPlatform.android]!;
      expect(after, lessThan(before));
      print(jsonEncode({
        'metric': 'mounted_request_rows_while_scrolling',
        'requests': 2000,
        'before': before,
        'after': after,
        'reduction_percent': (1 - after / before) * 100,
        'scope': 'same viewport and drag; not Android process RSS or device FPS',
      }));
    }
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.android}));
}
