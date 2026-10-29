import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/ios.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/plugins/ios_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MockIOSService extends Mock implements IOSService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockIOSService service;
  late CoreIOS core;

  setUpAll(() {
    registerFallbackValue(const CoreMethodCall(method: CoreMethod.getIsInit));
    AppPath.supportDirectory = () async => Directory.systemTemp;
    AppPath.temporaryDirectory = () async => Directory.systemTemp;
    AppPath.cacheDirectory = () async => Directory.systemTemp;
  });

  setUp(() {
    service = _MockIOSService();
    core = CoreIOS.scoped(service);
    CoreIOS.resetInstance();
  });

  group('lifecycle', () {
    test('start saves config and starts the tunnel', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);

      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .called(1);
      verify(() => service.start()).called(1);
    });

    test('start throws when the tunnel fails to start', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => false);

      expect(core.start(), throwsStateError);
    });

    test('stop shuts the tunnel down', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.stop();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.shutdown()).called(1);
    });

    test('restart stops then starts', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.restart();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.shutdown()).called(1);
      verify(() => service.start()).called(2);
    });

    test('start coalesces when already running', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
    });

    test('close marks the core closed and stops the tunnel', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.close();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.shutdown()).called(1);
    });

    test('start after close throws', () async {
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.close();
      expect(core.start(), throwsStateError);
    });
  });

  group('listener', () {
    test('startListener returns true when already running', () async {
      when(() => service.getStatus()).thenAnswer((_) async => true);

      expect(await core.startListener(), isTrue);
      verifyNever(() => service.start());
    });

    test('startListener starts when not running', () async {
      when(() => service.getStatus()).thenAnswer((_) async => false);
      when(() => service.start()).thenAnswer((_) async => true);

      expect(await core.startListener(), isTrue);
      verify(() => service.start()).called(1);
    });

    test('stopListener stops the tunnel', () async {
      when(() => service.stop()).thenAnswer((_) async => true);

      expect(await core.stopListener(), isTrue);
      verify(() => service.stop()).called(1);
    });
  });

  group('invokeMethod', () {
    test('forwards the call and unwraps the result', () async {
      when(() => service.saveConfig(homeDir: any(named: 'homeDir')))
          .thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.invokeMethod(any()))
          .thenAnswer((_) async => const CoreMethodResponse(result: true));

      await core.start();
      final result = await core.invokeMethod<bool>(
        method: CoreMethod.getIsInit,
      );

      expect(result, isTrue);
      verify(() => service.invokeMethod(any())).called(1);
    });

    test('returns null when the core never connects', () async {
      when(() => service.invokeMethod(any()))
          .thenAnswer((_) async => const CoreMethodResponse(result: true));

      final result = await core.invokeMethod<bool>(
        method: CoreMethod.getIsInit,
        timeout: const Duration(milliseconds: 50),
      );

      expect(result, isNull);
    });
  });
}
