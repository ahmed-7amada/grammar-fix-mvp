import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<String?> getModelFilePath(String filename) async {
  final appDir = await getApplicationDocumentsDirectory();
  final modelDir = Directory('${appDir.path}/models');
  if (!await modelDir.exists()) {
    await modelDir.create(recursive: true);
  }
  return '${modelDir.path}/$filename';
}

Future<bool> modelFileExists(String path) async {
  final file = File(path);
  return await file.exists();
}

Future<void> createModelDirectory(String path) async {
  final dir = Directory(path).parent;
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
}
