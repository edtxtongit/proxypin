import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/process_info.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/mobile/request/request.dart';
import 'package:proxypin/ui/mobile/request/request_sequence.dart';
import 'package:proxypin/utils/listenable_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackingQueue<T> extends Iterable<T> implements Queue<T> {
  final Queue<T> _queue;
  int indexedReads = 0;
  int snapshotReads = 0;

  _TrackingQueue(Iterable<T> items) : _queue = Queue.of(items);

  @override
  Iterator<T> get iterator => _queue.iterator;

  @override
  int get length => _queue.length;

  @override
  Queue<Result> cast<Result>() => _queue.cast<Result>();

  @override
  void add(T value) => _queue.add(value);

  @override
  void addAll(Iterable<T> items) => _queue.addAll(items);

  @override
  void addFirst(T value) => _queue.addFirst(value);

  @override
  void addLast(T value) => _queue.addLast(value);

  @override
  T removeFirst() => _queue.removeFirst();

  @override
  T removeLast() => _queue.removeLast();

  @override
  bool remove(Object? value) => _queue.remove(value);

  @override
  void removeWhere(bool Function(T) test) => _queue.removeWhere(test);

  @override
  void retainWhere(bool Function(T) test) => _queue.retainWhere(test);

  @override
  void clear() => _queue.clear();

  @override
  T elementAt(int index) {
    indexedReads++;
    return _queue.elementAt(index);
  }

  @override
  List<T> toList({bool growable = true}) {
    snapshotReads++;
    return _queue.toList(growable: growable);
  }
}

class _PendingIconProcess extends ProcessInfo {
  final Completer<Uint8List> iconResult = Completer<Uint8List>();
  int iconLoads = 0;

  _PendingIconProcess() : super('pending.app', 'Pending', '', os: 'android');

  @override
  Future<Uint8List> getIcon() {
    iconLoads++;
    return iconResult.future;
  }
}

HttpRequest _request(String id) => HttpRequest(HttpMethod.get, 'https://example.com/$id')..requestId = id;

HttpResponse _response(HttpRequest request, HttpStatus status, {String? body}) {
  final response = HttpResponse(status)..request = request;
  if (body != null) {
    response.body = body.codeUnits;
  }
  request.response = response;
  return response;
}

Widget _app(GlobalKey<RequestSequenceState> key, ListenableList<HttpRequest> container,
    {MultiSelectController? selectionController, Function(List<HttpRequest>)? onRemove}) {
  return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: MediaQuery(
              data: const MediaQueryData(size: Size(800, 600), devicePixelRatio: 3),
              child: RequestSequence(
                  key: key,
                  container: container,
                  proxyServer: ProxyServer(Configuration.fromJson({'enableSystemProxy': false, 'startup': false})),
                  selectionController: selectionController ?? MultiSelectController(),
                  onRemove: onRemove))));
}

RequestRow _buildRow(WidgetTester tester, ListView list, int index) {
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  return delegate.builder(tester.element(find.byType(ListView)), index * 2)! as RequestRow;
}

Future<void> _pumpApp(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Future<void> _unmountApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    RequestRowState.androidIconCache.clear();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    RequestRowState.androidIconCache.clear();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform keeps the expected indexing and scroll cache path', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final requests = List.generate(2000, (index) => _request('request-$index'));
      final key = GlobalKey<RequestSequenceState>();
      await _pumpApp(tester, _app(key, ListenableList(requests)));
      final queue = _TrackingQueue(requests.reversed);
      key.currentState!.view = queue;
      key.currentState!.changeState();
      await tester.pump(const Duration(milliseconds: 350));

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.scrollCacheExtent, ScrollCacheExtent.viewport(platform == TargetPlatform.android ? 0.5 : 2.0));
      final before = queue.indexedReads;
      final row = _buildRow(tester, list, 1500);
      expect(row.request, same(requests[499]));
      expect(queue.indexedReads - before, 1);
      expect(queue.snapshotReads, 0);
      await _unmountApp(tester);
    });
  }

  testWidgets('Android batches request refreshes without copying the capture queue', (tester) async {
    final first = _request('first');
    final second = _request('second');
    final key = GlobalKey<RequestSequenceState>();
    await _pumpApp(tester, _app(key, ListenableList([first, second])));
    final state = key.currentState!;
    final queue = _TrackingQueue([second, first]);
    state.view = queue;
    state.changeState();
    await tester.pump(const Duration(milliseconds: 350));
    for (int index = 0; index < 20; index++) {
      state.add(_request('new-$index'));
    }
    expect(queue.snapshotReads, 0);
    await tester.pump(const Duration(milliseconds: 349));
    expect(tester.widget<ListView>(find.byType(ListView)).semanticChildCount, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(queue.snapshotReads, 0);
    expect(tester.widget<ListView>(find.byType(ListView)).semanticChildCount, 22);

    state.addResponse(_response(second, HttpStatus.ok));
    await tester.pump();
    expect(queue.snapshotReads, 0);
    await _unmountApp(tester);
  });

  testWidgets('Android search, sort, response matches and selection removal remain available', (tester) async {
    final first = _request('match-first');
    final second = _request('other');
    final last = _request('match-last');
    final container = ListenableList([first, second, last]);
    final controller = MultiSelectController();
    final key = GlobalKey<RequestSequenceState>();
    await _pumpApp(
        tester,
        _app(key, container,
            selectionController: controller, onRemove: (removed) => container.removeWhere(removed.contains)));
    final state = key.currentState!;
    controller.selectOnly(second.requestId);
    state.search(SearchModel('match'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.currentView(), [last, first]);
    expect(controller.selectedIds, isEmpty);
    state.sort(false);
    await tester.pump();
    expect(state.currentView(), [first, last]);
    final added = _request('match-added');
    container.add(added);
    state.add(added);
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.currentView(), [first, last, added]);
    controller.selectOnly(first.requestId);
    expect(state.selectedRequests(), [first]);
    state.remove([first]);
    await tester.pump();
    expect(state.currentView(), [last, added]);
    expect(controller.selectedIds, isEmpty);
    final row = tester.widget<RequestRow>(find.byKey(ValueKey(last.requestId)));
    row.onRemove!(last);
    await tester.pump();
    expect(container.contains(last), isFalse);

    final search = SearchModel('response-match')..searchOptions = {Option.responseBody};
    state.search(search);
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.currentView(), isEmpty);
    state.addResponse(_response(second, HttpStatus.ok, body: 'response-match'));
    await tester.pump(const Duration(milliseconds: 350));
    state.addResponse(_response(added, HttpStatus.ok, body: 'response-match'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.currentView(), [second, added]);
    state.addResponse(added.response!);
    expect(state.currentView().length, 2);
    await _unmountApp(tester);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform response callback and clean lifecycle', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final request = _request('response');
      final key = GlobalKey<RequestSequenceState>();
      await _pumpApp(tester, _app(key, ListenableList([request])));
      final state = key.currentState!;
      state.addResponse(_response(request, HttpStatus.ok));
      await tester.pump();
      final rowState = tester.state<RequestRowState>(find.byType(RequestRow));
      expect(rowState.response!.status.code, 200);
      expect(state.responseCallbacks.containsKey(request.requestId), platform == TargetPlatform.android);
      state.clean();
      expect(state.responseCallbacks, isEmpty);
      await tester.pump();
      expect(state.responseCallbacks.containsKey(request.requestId), isTrue);
      state.addResponse(_response(request, HttpStatus.notFound));
      await tester.pump();
      expect(rowState.response!.status.code, 404);
      if (platform == TargetPlatform.android) {
        state.addResponse(_response(request, HttpStatus.badGateway));
        await tester.pump();
        expect(rowState.response!.status.code, 502);
      }
      await _unmountApp(tester);
      expect(state.responseCallbacks, isEmpty);
    });

    testWidgets('$platform cancels pending refreshes and ignores disposed highlight callbacks', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final key = GlobalKey<RequestSequenceState>();
      await _pumpApp(tester, _app(key, ListenableList([_request('first')])));
      final state = key.currentState!;
      final refreshRow = state.responseCallbacks.values.first;
      state.add(_request('pending'));
      state.highlightListener();
      await _unmountApp(tester);
      refreshRow();
      state.changeState();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('old row unmount cannot remove a newer response registration', (tester) async {
    final request = _request('same-id');
    final key = GlobalKey<RequestSequenceState>();
    await _pumpApp(tester, _app(key, ListenableList([request])));
    final state = key.currentState!;
    final list = tester.widget<ListView>(find.byType(ListView));
    final oldRow = _buildRow(tester, list, 0);
    final newRow = _buildRow(tester, list, 0);
    void oldRefresh() {}
    void newRefresh() {}
    oldRow.onMount!(oldRefresh);
    newRow.onMount!(newRefresh);
    oldRow.onUnmount!();
    expect(state.responseCallbacks[request.requestId], same(newRefresh));
    newRow.onUnmount!();
    expect(state.responseCallbacks, isEmpty);
    await _unmountApp(tester);
  });

  testWidgets('Android icon cache is bounded and decodes at display pixel size', (tester) async {
    final request = _request('icon');
    final key = GlobalKey<RequestSequenceState>();
    await _pumpApp(tester, _app(key, ListenableList([request])));
    final rowState = tester.state<RequestRowState>(find.byType(RequestRow));
    final bytes = Uint8List.fromList([1, 2, 3]);
    Image? first;
    for (int index = 0; index <= RequestRowState.maxAndroidIconEntries; index++) {
      request.processInfo = ProcessInfo('app-$index', 'App', '', os: 'android', icon: bytes);
      final image = rowState.appIcon()! as Image;
      first ??= image;
      expect(image.width, 40);
      expect((image.image as ResizeImage).width, 120);
      expect(rowState.appIcon(), same(image));
    }
    expect(RequestRowState.androidIconCache.length, RequestRowState.maxAndroidIconEntries);
    expect(RequestRowState.androidIconCache.get(('app-0', 120)), isNull);
    expect(RequestRowState.imageCache.containsKey('app-0'), isFalse);
    request.processInfo = ProcessInfo('app-0', 'App', '', os: 'android', icon: bytes);
    expect(rowState.appIcon(), isNot(same(first)));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(rowState.appIcon(), isNull);
    await _unmountApp(tester);
  });

  testWidgets('Android reuses the pending icon future and sizes the async result', (tester) async {
    final request = _request('pending-icon');
    final process = _PendingIconProcess();
    request.processInfo = process;
    final key = GlobalKey<RequestSequenceState>();
    await _pumpApp(tester, _app(key, ListenableList([request])));
    final rowState = tester.state<RequestRowState>(find.byType(RequestRow));
    final first = rowState.appIcon()! as FutureBuilder<Uint8List>;
    final second = rowState.appIcon()! as FutureBuilder<Uint8List>;
    expect(first.future, same(second.future));
    expect(process.iconLoads, 1);
    final image = first.builder(
        rowState.context, AsyncSnapshot.withData(ConnectionState.done, Uint8List.fromList([1, 2, 3]))) as Image;
    expect((image.image as ResizeImage).width, 120);
    await _unmountApp(tester);
    process.iconResult.complete(Uint8List(0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
