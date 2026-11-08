import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;

import '../helpers/app_paths.dart';

Uint8List _database(int length, {String marker = ''}) {
  final bytes = Uint8List(length)..fillRange(0, length, 0x20);
  final tail = marker.codeUnits;
  bytes.setRange(length - tail.length, length, tail);
  return bytes;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('flclash_geo');
    await useAppPaths(root);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('a downloaded database lands where the Core reads it', () async {
    final bytes = _database(512 * 1024, marker: 'MaxMind.com');

    final file = await storeGeoDatabase(GeoResource.MMDB, bytes);

    expect(file.path, join(root.path, MMDB));
    expect(await file.readAsBytes(), bytes);
    expect(await File('${file.path}.download').exists(), isFalse);
  });

  test('a download that is not a database is refused', () async {
    final bytes = _database(1024);

    await expectLater(
      storeGeoDatabase(GeoResource.GEOSITE, bytes),
      throwsA(isA<MessageException>()),
    );
    expect(await File(join(root.path, GEOSITE)).exists(), isFalse);
  });

  test('an MMDB without its marker counts as a failed download', () {
    expect(
      looksLikeGeoDatabase(GeoResource.MMDB, _database(512 * 1024)),
      false,
    );
    expect(
      looksLikeGeoDatabase(
        GeoResource.MMDB,
        _database(512 * 1024, marker: 'MaxMind.com'),
      ),
      true,
    );
  });
}
