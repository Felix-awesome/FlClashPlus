import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/ios.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/plugins/ios_service.dart';
import 'package:flutter/services.dart';
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
      when(() => service.getStatus()).thenAnswer((_) async => true);

      await core.start();
      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
    });

    // The tunnel does not belong to the app: the system can drop it, the user
    // can switch it off, and preparing a start rewrites its configuration,
    // which stops it. A gate that stays completed after that reported "already
    // running" for the rest of the session, so nothing could bring the tunnel
    // back without relaunching.
    test('start starts again when the tunnel it built is gone', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.getStatus()).thenAnswer((_) async => false);

      await core.start();
      final result = await core.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      verify(() => service.start()).called(2);
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

  group('validateConfig', () {
    // A profile can only be checked by a core, and on iOS the core only exists
    // inside the tunnel extension. With the VPN off there is nothing to ask, so
    // the call is answered "nothing to report" instead of failing: refusing it
    // blocked adding a subscription before the first connection, which is when
    // one is usually added, and the message named the missing core rather than
    // anything about the config.
    test('accepts a profile unvalidated when no tunnel is running', () async {
      when(() => service.getStatus()).thenAnswer((_) async => false);

      final message = await core.validateConfig('/tmp/flclash-profile.yaml');

      expect(message, isEmpty);
      verifyNever(() => service.invokeMethod(any()));
    });

    test('forwards the check when the core is up', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(
        () => service.invokeMethod(any()),
      ).thenAnswer((_) async => const CoreMethodResponse(result: 'bad proxy'));

      await core.start();
      final message = await core.validateConfig('/tmp/flclash-profile.yaml');

      expect(message, 'bad proxy');
      verify(() => service.invokeMethod(any())).called(1);
    });

    // A tunnel that was there a moment ago can be gone by the time the file
    // arrives: rewriting the tunnel's configuration stops the provider, and a
    // reply then never comes. Failing the import for that reported a config
    // problem that did not exist.
    test('accepts a profile the extension could not answer for', () async {
      when(
        () => service.saveConfig(homeDir: any(named: 'homeDir')),
      ).thenAnswer((_) async => true);
      when(() => service.start()).thenAnswer((_) async => true);
      when(() => service.getStatus()).thenAnswer((_) async => true);
      when(() => service.invokeMethod(any())).thenThrow(
        PlatformException(code: 'send_failed'),
      );

      await core.start();
      final message = await core.validateConfig('/tmp/flclash-profile.yaml');

      expect(message, isEmpty);
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
