import 'dart:io';

import 'package:flutter/services.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/cache.dart';
import 'package:proxypin/network/util/process_info.dart';

class ProcessInfoPlugin {
  static const MethodChannel _methodChannel = MethodChannel('com.proxy/processInfo');
  static final _icons = LruCache<(String, String?), (Uint8List, DateTime)>(128);

  static Future<ProcessInfo?> getProcessByPort(String host, int port) {
    return _methodChannel.invokeMethod<Map>('getProcessByPort', {"host": host, "port": port}).then((process) {
      if (process == null) return null;

      var icon = process['icon'] as Uint8List?;
      if (icon != null && icon.isNotEmpty) {
        final key = (process['packageName'] as String, process['versionName'] as String?);
        final cached = _icons.get(key);
        final now = DateTime.now();
        if (cached != null && now.difference(cached.$2) < const Duration(minutes: 5)) {
          icon = cached.$1;
        } else {
          _icons.set(key, (icon, now));
        }
      }

      return ProcessInfo(process['packageName'], process['name'], process['packageName'],
          os: Platform.operatingSystem,
          icon: icon,
          remoteHost: process['remoteHost'],
          remotePost: process['remotePort']);
    });
  }

  static Future<HostAndPort?> getRemoteAddressByPort(int port) async {
    if (!Platform.isAndroid) return null;

    return _methodChannel.invokeMethod<Map>('getRemoteAddressByPort', {"port": port}).then((process) {
      if (process == null) return null;
      return HostAndPort.host(process['remoteHost'], process['remotePort']);
    });
  }
}
