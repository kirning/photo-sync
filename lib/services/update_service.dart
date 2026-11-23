import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_log.dart';

/// 新版本信息（来自 GitHub Releases）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.assetName,
    this.size = 0,
    this.publishedAt,
  });

  /// 去掉前缀 v 的版本号，例如 `0.2.0`。
  final String version;
  final String tagName;
  final String notes;
  final String pageUrl;
  final String? apkUrl;
  final String? assetName;
  final int size;
  final DateTime? publishedAt;

  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;
}

/// 更新过程中的错误，消息可以直接展示给用户。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从 GitHub Releases 检查、下载并安装新版本。
class UpdateService {
  const UpdateService._();

  static const String repository = 'kirning/photo-sync';
  static const String _apiUrl =
      'https://api.github.com/repos/$repository/releases/latest';
  static const String _releasePage = 'https://github.com/$repository/releases';

  static const MethodChannel _channel = MethodChannel('photo_sync/install');

  /// 查询最新正式版本；失败抛 [UpdateException]。
  static Future<UpdateInfo> fetchLatest({
    String? preferredAbi,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(_apiUrl)).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader,
          'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'photo-sync-android');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(timeout);
      if (response.statusCode == 404) {
        throw const UpdateException('仓库还没有发布任何版本');
      }
      if (response.statusCode != 200) {
        throw UpdateException('检查更新失败（HTTP ${response.statusCode}）');
      }
      final body = await utf8.decodeStream(response).timeout(timeout);
      final json = jsonDecode(body);
      if (json is! Map) {
        throw const UpdateException('检查更新失败：返回内容无法识别');
      }
      return parseRelease(json.cast<String, dynamic>(),
          preferredAbi: preferredAbi);
    } on SocketException catch (error) {
      throw UpdateException('无法连接 GitHub：${error.message}');
    } on TimeoutException {
      throw const UpdateException('检查更新超时，请检查网络后再试');
    } on HandshakeException {
      throw const UpdateException('与 GitHub 的加密连接失败，请检查网络');
    } on FormatException {
      throw const UpdateException('检查更新失败：返回内容无法解析');
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 GitHub 的 release JSON（纯函数，便于单测）。
  static UpdateInfo parseRelease(
    Map<String, dynamic> json, {
    String? preferredAbi,
  }) {
    final tag = '${json['tag_name'] ?? json['name'] ?? ''}'.trim();
    final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
    final body = '${json['body'] ?? ''}'.trim();
    final htmlUrl = '${json['html_url'] ?? _releasePage}';
    final publishedAt = DateTime.tryParse('${json['published_at'] ?? ''}');

    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .where((item) => '${item['name'] ?? ''}'.toLowerCase().endsWith('.apk'))
        .toList();

    if (assets.isEmpty) {
      return UpdateInfo(
        version: version,
        tagName: tag,
        notes: body,
        pageUrl: htmlUrl,
        publishedAt: publishedAt,
      );
    }

    // 优先匹配设备 ABI，其次按常见顺序兜底。
    final priorities = <String>[
      if (preferredAbi != null && preferredAbi.isNotEmpty) preferredAbi,
      'arm64-v8a',
      'armeabi-v7a',
      'x86_64',
      'universal',
    ];
    Map<String, dynamic>? chosen;
    for (final abi in priorities) {
      for (final asset in assets) {
        final name = '${asset['name']}'.toLowerCase();
        if (name.contains(abi.toLowerCase())) {
          chosen = asset;
          break;
        }
      }
      if (chosen != null) break;
    }
    chosen ??= assets.first;

    return UpdateInfo(
      version: version,
      tagName: tag,
      notes: body,
      pageUrl: htmlUrl,
      apkUrl: chosen['browser_download_url'] as String?,
      assetName: '${chosen['name'] ?? ''}',
      size: (chosen['size'] as num?)?.toInt() ?? 0,
      publishedAt: publishedAt,
    );
  }

  /// 版本号比较：latest 比 current 新返回 true。
  static bool isNewerVersion(String latest, String current) {
    final a = _versionParts(latest);
    final b = _versionParts(current);
    if (a.isEmpty || b.isEmpty) return false;
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static List<int> _versionParts(String value) => RegExp(r'\d+')
      .allMatches(value)
      .map((match) => int.tryParse(match.group(0)!) ?? 0)
      .toList();

  /// 当前设备的首选 ABI（拿不到时按 arm64-v8a 处理）。
  static Future<String> deviceAbi() async {
    try {
      final abi = await _channel.invokeMethod<String>('deviceAbi');
      if (abi != null && abi.isNotEmpty) return abi;
    } catch (_) {
      // 桌面/测试环境没有这个通道。
    }
    return 'arm64-v8a';
  }

  /// 下载安装包到 [dir]，返回本地文件。
  static Future<File> download(
    UpdateInfo info,
    Directory dir, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = info.apkUrl;
    if (url == null || url.isEmpty) {
      throw const UpdateException('该版本没有提供安装包');
    }
    await dir.create(recursive: true);
    final name = (info.assetName == null || info.assetName!.isEmpty)
        ? 'photo-sync-${info.version}.apk'
        : info.assetName!;
    final target = File(p.join(dir.path, name));
    final part = File('${target.path}.part');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'photo-sync-android');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw UpdateException('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength > 0 ? response.contentLength : info.size;
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          throw const UpdateException('已取消下载');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      AppLog.instance.info('update', '已下载 ${info.version}：${target.path}');
      return target;
    } on SocketException catch (error) {
      throw UpdateException('下载失败：${error.message}');
    } on TimeoutException {
      throw const UpdateException('下载超时');
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 忽略
      }
      client.close(force: true);
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {
          // 忽略
        }
      }
    }
  }

  /// 调起系统安装界面。
  static Future<void> installApk(File apk) async {
    if (!await apk.exists()) {
      throw const UpdateException('安装包不存在，请重新下载');
    }
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apk.path});
    } on PlatformException catch (error) {
      throw UpdateException(error.message ?? '无法启动安装程序');
    }
  }

  /// 打开 Release 页面（由调用方用 url_launcher 之类的工具打开）。
  static String releasePageFor(UpdateInfo info) =>
      info.pageUrl.isEmpty ? _releasePage : info.pageUrl;
}
