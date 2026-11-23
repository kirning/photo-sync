import 'dart:convert';
import 'dart:io';

/// 原子写入的 JSON 文件封装。
///
/// 上传任务会在后台 isolate 中同时写状态文件，因此全部采用
/// “写临时文件 -> 重命名” 的方式，避免读到半个文件。
class JsonFile {
  JsonFile(this.file);

  final File file;

  Future<Map<String, dynamic>?> readObject() async {
    final text = await readText();
    if (text == null || text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<List<dynamic>?> readList() async {
    final text = await readText();
    if (text == null || text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<String?> readText() async {
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> writeAtomic(Object? data) =>
      writeStringAtomic(const JsonEncoder.withIndent('  ').convert(data));

  Future<void> writeStringAtomic(String text) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows 上目标存在时 rename 可能失败。
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    }
  }
}
