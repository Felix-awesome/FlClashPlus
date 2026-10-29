import 'dart:convert';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/ios_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const vpnChannelName = '$packageName/ios_vpn';
  const coreChannelName = '$packageName/core';
  const vpnChannel = MethodChannel(vpnChannelName);
  const coreChannel = MethodChannel(coreChannelName);

  late List<MethodCall> calls;

  void mockVpnChannel(
    Future<Object?>? Function(MethodCall call) handler,
  ) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  void mockCoreChannel(
    Future<Object?>? Function(MethodCall call) handler,
  ) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(coreChannel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    calls = <MethodCall>[];
  });

  tearDown(() {
    for (final channel in [vpnChannel, coreChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  group('getStatus', () {
    test('reports running from the platform map', () async {
      mockVpnChannel((_) async => {'running': true});

      expect(await IOSService().getStatus(), isTrue);
      expect(calls.single.method, 'getStatus');
    });

    test('treats a missing map or running flag as not running', () async {
      mockVpnChannel((_) async => null);
      expect(await IOSService().getStatus(), isFalse);

      mockVpnChannel((_) async => <String, Object?>{});
      expect(await IOSService().getStatus(), isFalse);
    });

    test('swallows a platform error and reports not running', () async {
      mockVpnChannel((_) async => throw PlatformException(code: 'boom'));

      expect(await IOSService().getStatus(), isFalse);
    });
  });

  group('saveConfig', () {
    test('forwards the config and returns the platform result', () async {
      mockVpnChannel((_) async => true);

      expect(
        await IOSService().saveConfig(homeDir: '/tmp/home'),
        isTrue,
      );

      final args = calls.single.arguments as Map;
      expect(calls.single.method, 'saveConfig');
      expect(args['homeDir'], '/tmp/home');
      expect(args['stack'], 'gvisor');
      expect(args['address'], '198.18.0.1/30');
      expect(args['dns'], '198.18.0.1');
    });

    test('treats an absent result as failure', () async {
      mockVpnChannel((_) async => null);

      expect(await IOSService().saveConfig(homeDir: '/tmp/home'), isFalse);
    });
  });

  group('lifecycle commands', () {
    test('requestPermission forwards and returns the result', () async {
      mockVpnChannel((_) async => true);

      expect(await IOSService().requestPermission(), isTrue);
      expect(calls.single.method, 'requestPermission');
    });

    test('start and stop return the platform result', () async {
      mockVpnChannel((call) async => call.method == 'start');

      expect(await IOSService().start(), isTrue);
      expect(await IOSService().stop(), isFalse);
      expect(calls.map((call) => call.method), ['start', 'stop']);
    });

    test('an absent start or stop result is treated as failure', () async {
      mockVpnChannel((_) async => null);

      expect(await IOSService().start(), isFalse);
      expect(await IOSService().stop(), isFalse);
    });

    test('shutdown stops the tunnel and reports success', () async {
      mockVpnChannel((_) async => true);

      expect(await IOSService().shutdown(), isTrue);
      expect(calls.single.method, 'stop');
    });

    test('init and syncState are no-ops returning empty', () async {
      expect(await IOSService().init(), isEmpty);
      expect(
        await IOSService().syncState(
          const SharedState(
            stopTip: 's',
            startTip: 's',
            localNetworkTip: 's',
            currentProfileName: 'p',
            stopText: 's',
            onlyStatisticsProxy: false,
          ),
        ),
        isEmpty,
      );
    });
  });

  group('getRunTime', () {
    test('maps a millisecond stamp to a DateTime', () async {
      final stamp = DateTime.utc(2026, 8, 16).millisecondsSinceEpoch;
      mockVpnChannel((_) async => stamp);

      expect(
        await IOSService().getRunTime(),
        DateTime.fromMillisecondsSinceEpoch(stamp),
      );
    });

    test('treats zero and a missing stamp as not running', () async {
      mockVpnChannel((_) async => 0);
      expect(await IOSService().getRunTime(), isNull);

      mockVpnChannel((_) async => null);
      expect(await IOSService().getRunTime(), isNull);
    });
  });

  group('invokeMethod', () {
    test('encodes the call and decodes the response envelope', () async {
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode(
            const CoreMethodResponse(id: '7', result: {'up': 1}).toJson(),
          ),
        ),
      );

      final response = await IOSService().invokeMethod(
        const CoreMethodCall(id: '7', method: CoreMethod.getTraffic),
      );

      final sent =
          json.decode(calls.single.arguments as String) as Map<String, Object?>;
      expect(calls.single.method, 'invokeMethod');
      expect(sent['id'], '7');
      expect(sent['method'], CoreMethod.getTraffic.name);
      expect(response!.id, '7');
      expect(response.result, {'up': 1});
    });

    test('decodes a large UTF-8 envelope off the calling isolate', () async {
      final names = List.generate(5000, (index) => '节点-$index');
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode(CoreMethodResponse(id: '3', result: names).toJson()),
        ),
      );

      final response = await IOSService().invokeMethod(
        const CoreMethodCall(id: '3', method: CoreMethod.getProxies),
      );

      expect(response!.result, names);
    });

    test('returns null when the platform sends no envelope', () async {
      mockCoreChannel((_) async => null);

      expect(
        await IOSService().invokeMethod(
          const CoreMethodCall(method: CoreMethod.getTraffic),
        ),
        isNull,
      );
    });

    test('surfaces a Core error inside the envelope', () async {
      mockCoreChannel(
        (_) async => utf8.encode(
          json.encode({
            'id': '1',
            'result': null,
            'error': {'code': 'unavailable', 'message': 'core down'},
          }),
        ),
      );

      final response = await IOSService().invokeMethod(
        const CoreMethodCall(id: '1', method: CoreMethod.getTraffic),
      );

      expect(response!.error, isNotNull);
      expect(response.error!.code, 'unavailable');
      expect(response.error!.message, 'core down');
    });
  });

  group('top-level getter', () {
    test('iosService getter returns null off iOS', () {
      expect(iosService, isNull);
    });
  });
}
