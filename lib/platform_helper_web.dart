// Web platform - no file system access needed
// Models are loaded via MLC model IDs

Future<String?> getModelFilePath(String filename) async {
  // On web, we use MLC model IDs, not file paths
  return null;
}

Future<bool> modelFileExists(String path) async {
  // On web, models are managed by MLC
  return false;
}

Future<void> createModelDirectory(String path) async {
  // No-op on web
}
