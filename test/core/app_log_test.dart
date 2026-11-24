import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/app_log.dart';

void main() {
  test('日志会落盘，并且可以按内容读回', () async {
    final dir = await Directory.systemTemp.createTemp('photo_sync_log_');
    addTearDown(() async {
      await AppLog.instance.closeFile();
      AppLog.instance.clear();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    await AppLog.instance.init(dir);
    AppLog.instance.info('test', '第一行中文日志');
    AppLog.instance.error('test', '第二行', '因为网络不通');

    final text = await AppLog.instance.readPersisted();
    expect(text, contains('第一行中文日志'));
    expect(text, contains('第二行: 因为网络不通'));
  });

  test('日志文件超过上限会轮转到 app.log.1', () async {
    final dir = await Directory.systemTemp.createTemp('photo_sync_log_');
    addTearDown(() async {
      await AppLog.instance.closeFile();
      AppLog.instance.clear();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final file = File('${dir.path}${Platform.pathSeparator}app.log');
    await file.writeAsString('x' * (600 * 1024));

    await AppLog.instance.init(dir);
    expect(await File('${file.path}.1').exists(), isTrue);
    AppLog.instance.info('test', '轮转之后的日志');
    expect(await file.exists(), isTrue);
    expect(await file.length(), lessThan(1000));
  });
}
