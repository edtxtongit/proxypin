import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/native/process_info.dart';
import 'package:proxypin/network/util/process_info.dart' as capture;

const processChannel = MethodChannel('com.proxy/processInfo');

Future<capture.ProcessInfo> originalLookup(String host, int port) async {
  final process = (await processChannel.invokeMethod<Map>('getProcessByPort', {'host': host, 'port': port}))!;
  return capture.ProcessInfo(process['packageName'], process['name'], process['packageName'],
      os: Platform.operatingSystem,
      icon: process['icon'],
      remoteHost: process['remoteHost'],
      remotePost: process['remotePort']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(processChannel, null));

  test('Android icon payloads are shared without sharing connection metadata', () async {
    const requestCount = 2000;
    const iconBytes = 32768;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        processChannel,
        (call) async => {
              'packageName': 'benchmark.app',
              'name': 'Benchmark',
              'versionName': '1.0',
              'icon': Uint8List.fromList(List.generate(iconBytes, (index) => index % 251)),
              'remoteHost': call.arguments['host'],
              'remotePort': call.arguments['port'],
            });
    final original = <capture.ProcessInfo>[];
    final optimized = <capture.ProcessInfo>[];
    for (var index = 0; index < requestCount; index++) {
      original.add(await originalLookup('host$index', index));
      optimized.add((await ProcessInfoPlugin.getProcessByPort('host$index', index))!);
    }
    final originalIcons = original.map((process) => process.icon!).toSet();
    final optimizedIcons = optimized.map((process) => process.icon!).toSet();
    final originalBytes = originalIcons.fold<int>(0, (total, icon) => total + icon.lengthInBytes);
    final optimizedBytes = optimizedIcons.fold<int>(0, (total, icon) => total + icon.lengthInBytes);
    expect(originalIcons.length, requestCount);
    expect(optimizedIcons.length, 1);
    expect(optimized.toSet().length, requestCount);
    expect(optimized.last.remoteHost, 'host1999');
    expect(optimized.last.remotePost, 1999);
    expect(optimized.first.icon, original.first.icon);
    print(jsonEncode({
      'metric': 'retained_android_icon_payload_bytes',
      'requests': requestCount,
      'before': originalBytes,
      'after': optimizedBytes,
      'reduction_percent': (1 - optimizedBytes / originalBytes) * 100,
      'scope': 'icon buffers only; not Android process RSS',
    }));
  });

  test('Android icon sharing respects app version changes and LRU eviction', () async {
    var version = '1.0';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        processChannel,
        (call) async => {
              'packageName': call.arguments['host'],
              'name': 'App',
              'versionName': version,
              'icon': Uint8List.fromList([version == '1.0' ? 1 : 2]),
            });
    final first = (await ProcessInfoPlugin.getProcessByPort('version.app', 1))!;
    final repeated = (await ProcessInfoPlugin.getProcessByPort('version.app', 2))!;
    expect(repeated.icon, same(first.icon));
    version = '2.0';
    final updated = (await ProcessInfoPlugin.getProcessByPort('version.app', 3))!;
    expect(updated.icon, isNot(same(first.icon)));
    expect(updated.icon, [2]);
    for (var index = 0; index < 128; index++) {
      await ProcessInfoPlugin.getProcessByPort('eviction$index.app', index);
    }
    final reloaded = (await ProcessInfoPlugin.getProcessByPort('version.app', 4))!;
    expect(reloaded.icon, isNot(same(updated.icon)));
    expect(reloaded.icon, [2]);
  });

  test('Android native lookup preserves missing process and icon responses', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(processChannel,
        (call) async => call.arguments['port'] == 0 ? null : {'packageName': 'no.icon.app', 'name': 'No icon'});
    expect(await ProcessInfoPlugin.getProcessByPort('localhost', 0), isNull);
    final process = (await ProcessInfoPlugin.getProcessByPort('localhost', 1))!;
    expect(process.icon, isNull);
    expect(process.id, 'no.icon.app');
  });
}
