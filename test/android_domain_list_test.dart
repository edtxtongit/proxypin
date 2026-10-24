import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/mobile/request/domians.dart';
import 'package:proxypin/utils/listenable_list.dart';

HttpRequest domainRequest(String host) {
  return HttpRequest(HttpMethod.get, 'https://$host/path')..hostAndPort = HostAndPort.host(host, 443);
}

Widget domainPage(GlobalKey<DomainListState> stateKey) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: DomainList(
        key: stateKey,
        list: ListenableList<HttpRequest>(),
        proxyServer: ProxyServer(Configuration.fromJson({})),
      ),
    ),
  );
}

void main() {
  testWidgets('Android batches domain snapshots without dropping requests', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    final state = stateKey.currentState!;

    for (var index = 0; index < 2000; index++) {
      state.add(domainRequest('host$index.example'));
    }
    expect(state.view, isEmpty);
    expect(state.containerMap.length, 2000);
    await tester.pump(const Duration(milliseconds: 99));
    expect(state.view, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(state.view.length, 2000);
    expect(state.view.first.host, 'host1999.example');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android keeps one request for a websocket upgrade', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    final state = stateKey.currentState!;
    final request = domainRequest('websocket.example');
    state.add(request);
    final response = HttpResponse(HttpStatus.ok)..request = request;
    response.headers.set('Upgrade', 'websocket');
    request.response = response;
    state.addResponse(response);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.containerMap[request.hostAndPort], [request]);
    expect(state.view, [request.hostAndPort]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android applies the active filter to a batched snapshot', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    final state = stateKey.currentState!;
    state.search(SearchModel('match'));
    state.add(domainRequest('match.example'));
    state.add(domainRequest('other.example'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.view.map((host) => host.host), ['match.example']);
    expect(state.containerMap.length, 2);
    state.search(SearchModel());
    expect(state.view.length, 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android releases empty domain buckets after request removal', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    final state = stateKey.currentState!;
    final request = domainRequest('removed.example');
    state.add(request);
    state.remove([request]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.containerMap, isEmpty);
    expect(state.view, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android cancels a pending refresh when disposed', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    stateKey.currentState!.add(domainRequest('pending.example'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('iOS retains its existing immediate domain view update', (tester) async {
    final stateKey = GlobalKey<DomainListState>();
    await tester.pumpWidget(domainPage(stateKey));
    await tester.pumpAndSettle();
    final state = stateKey.currentState!;
    final request = domainRequest('ios.example');
    state.add(request);
    expect(state.view, [request.hostAndPort]);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
