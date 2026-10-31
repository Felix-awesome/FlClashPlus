import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/ios.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/plugins/ios_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);

      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).called(1);
      verify(() => service.start()).called(1);
    });

    test('start throws when the tunnel fails to start', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => false);

      expect(core.start(), throwsStateError);
    });

    // A failed save means the extension has no home dir to read, so opening the
    // tunnel anyway only buys a core-call timeout that hides the real cause.
    test('start skips the tunnel when the config was not saved', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => false);

      await expectLater(core.start(), throwsStateError);
      verifyNever(() => service.start());
    });

    test('stop shuts the tunnel down', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.stop();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.shutdown()).called(1);
    });

    test('restart stops then starts', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.shutdown()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.restart();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.shutdown()).called(1);
      verify(() => service.start()).called(2);
    });

    test('start coalesces when already running', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
    });

    test('close marks the core closed and stops the tunnel', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
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
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(
        () => service.invokeMethod(any()),
      ).thenAnswer((_) async => const CoreMethodResponse(result: true));

      await core.start();
      final result = await core.invokeMethod<bool>(
        method: CoreMethod.getIsInit,
      );

      expect(result, isTrue);
      verify(() => service.invokeMethod(any())).called(1);
    });

    test('returns null when the core never connects', () async {
      when(() => service.getStatus()).thenAnswer((_) async => true);
      when(
        () => service.invokeMethod(any()),
      ).thenAnswer((_) async => const CoreMethodResponse(result: true));

      final result = await core.invokeMethod<bool>(
        method: CoreMethod.getIsInit,
        timeout: const Duration(milliseconds: 50),
      );

      expect(result, isNull);
    });

    // With no tunnel there is nobody to answer, and waiting the connection
    // timeout out for a call that can never arrive is what made adding a
    // profile with the VPN off look like a hang.
    test('a call with no tunnel is skipped instead of waited out', () async {
      when(() => service.getStatus()).thenAnswer((_) async => false);
      when(
        () => service.invokeMethod(any()),
      ).thenAnswer((_) async => const CoreMethodResponse(result: true));

      final watch = Stopwatch()..start();
      final result = await core.invokeMethod<bool>(
        method: CoreMethod.getIsInit,
      );
      watch.stop();

      expect(result, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      verifyNever(() => service.invokeMethod(any()));
    });

    // The system can bring the tunnel back on its own (on-demand, a relaunch),
    // and the app only learns about it from a status query. That tunnel is
    // worth waiting for: its extension is booting a core right now.
    test('a call waits for a tunnel the system started by itself', () async {
      when(() => service.getStatus()).thenAnswer((_) async => true);
      when(
        () => service.invokeMethod(any()),
      ).thenAnswer((_) async => const CoreMethodResponse(result: true));

      final pending = core.invokeMethod<bool>(method: CoreMethod.getIsInit);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await core.startListener();

      expect(await pending, isTrue);
      verify(() => service.invokeMethod(any())).called(1);
    });
  });
}
