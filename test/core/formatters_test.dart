import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/formatters.dart';

void main() {
  group('Fmt.bytes', () {
    test('字节与单位', () {
      expect(Fmt.bytes(0), '0 B');
      expect(Fmt.bytes(1023), '1023 B');
      expect(Fmt.bytes(1024), '1.0 KB');
      expect(Fmt.bytes(1536), '1.5 KB');
      expect(Fmt.bytes(1024 * 1024), '1.0 MB');
      expect(Fmt.bytes(200 * 1024 * 1024), '200 MB');
      expect(Fmt.bytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('负数', () {
      expect(Fmt.bytes(-1), '-');
    });
  });

  group('Fmt.count', () {
    test('万与亿', () {
      expect(Fmt.count(9999), '9999');
      expect(Fmt.count(10000), '1.0 万');
      expect(Fmt.count(123456), '12.3 万');
      expect(Fmt.count(123456789), '1.23 亿');
    });
  });

  group('Fmt.duration', () {
    test('秒/分/时', () {
      expect(Fmt.duration(const Duration(seconds: 45)), '45 秒');
      expect(Fmt.duration(const Duration(minutes: 2, seconds: 5)), '2 分 5 秒');
      expect(Fmt.duration(const Duration(hours: 1, minutes: 3)), '1 时 3 分');
    });
  });

  group('Fmt.percent', () {
    test('夹取与保留一位小数', () {
      expect(Fmt.percent(0.5), '50.0%');
      expect(Fmt.percent(1.5), '100.0%');
      expect(Fmt.percent(-1), '0.0%');
      expect(Fmt.percent(double.nan), '0%');
    });
  });

  group('Fmt.eta', () {
    test('正常估算', () {
      expect(Fmt.eta(1024, 1024), '1 秒');
      expect(Fmt.eta(2048, 1024), '2 秒');
    });

    test('无法估算', () {
      expect(Fmt.eta(0, 1024), '--');
      expect(Fmt.eta(1024, 0), '--');
    });
  });

  group('日期', () {
    test('格式化', () {
      final value = DateTime(2026, 3, 4, 5, 6);
      expect(Fmt.date(value), '2026-03-04');
      expect(Fmt.dateTime(value), '2026-03-04 05:06');
    });

    test('相对时间', () {
      expect(Fmt.relative(DateTime.now()), '刚刚');
      expect(
        Fmt.relative(DateTime.now().subtract(const Duration(minutes: 5))),
        '5 分钟前',
      );
    });
  });
}
