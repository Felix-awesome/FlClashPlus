import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/common/common.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class Picker {
  Future<PlatformFile?> pickerFile() async {
    return FilePicker.pickFile(initialDirectory: await appPath.downloadDirPath);
  }

  Future<Uri?> saveFile(String fileName, Uint8List bytes) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: await appPath.downloadDirPath,
      bytes: bytes,
    );
    // `FilePicker.saveFile` already writes `bytes` to the location the user
    // picked, on every platform. Writing again from `uri.toFilePath()` is
    // wrong on iOS: the picker returns a security-scoped URL there, and a
    // plain `File.writeAsBytes` against it fails with
    // `Operation not permitted`, which made the "export extension log" (and
    // every other export through this helper) report success then throw.
    return uri;
  }

  Future<Uri?> saveFileWithPath(String fileName, String localPath) async {
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      await localFile.create(recursive: true);
    }
    final bytes = await localFile.readAsBytes();
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: await appPath.downloadDirPath,
      bytes: bytes,
    );
    await localFile.safeDelete();
    return uri;
  }

  Future<String?> pickerConfigQRCode() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xFile == null) {
      return null;
    }
    // Not through a throwaway MobileScannerController: disposing one clears
    // the platform scan window of a scanner page that is still open.
    final capture = await MobileScannerPlatform.instance.analyzeImage(
      xFile.path,
      formats: const [BarcodeFormat.qrCode],
    );
    final url = profileUrlFromQrCodes(
      capture?.barcodes.map((barcode) => barcode.rawValue) ?? const [],
    );
    if (url == null) {
      throw MessageException(currentAppLocalizations.pleaseUploadValidQrcode);
    }
    return url;
  }
}

extension PlatformFileExt on PlatformFile {
  Future<Uint8List> readBytes() {
    return readAsBytes();
  }
}

final picker = Picker();
