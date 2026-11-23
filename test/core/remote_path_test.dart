import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/remote_path.dart';

void main() {
  group('normalizeRoot', () {
    test('去掉多余斜杠与首尾空白', () {
      expect(RemotePathUtil.normalizeRoot(' /a//b/ '), 'a/b');
      expect(RemotePathUtil.normalizeRoot('/'), '');
      expect(RemotePathUtil.normalizeRoot(''), '');
    });

    test('反斜杠与 .. 段', () {
      expect(RemotePathUtil.normalizeRoot(r'\photo\..\2026'), 'photo/2026');
    });
  });

  group('sanitizeSegment', () {
    test('非法字符替换为下划线', () {
      expect(RemotePathUtil.sanitizeSegment('a:b*c?'), 'a_b_c_');
      expect(RemotePathUtil.sanitizeSegment('a<b>c|d"e'), 'a_b_c_d_e');
    });

    test('空白回退为未命名', () {
      expect(RemotePathUtil.sanitizeSegment('   '), '未命名');
      expect(RemotePathUtil.sanitizeSegment(''), '未命名');
    });

    test('去掉首尾点与连续空白', () {
      expect(RemotePathUtil.sanitizeSegment('..a  b..'), 'a b');
    });

    test('Windows 保留名加前缀', () {
      expect(RemotePathUtil.sanitizeSegment('CON'), '_CON');
      expect(RemotePathUtil.sanitizeSegment('lpt1'), '_lpt1');
    });

    test('超长截断到 100 个字符', () {
      final long = 'a' * 150;
      expect(RemotePathUtil.sanitizeSegment(long).length, 100);
    });
  });

  group('sanitizeFileName', () {
    test('扩展名转小写并清洗', () {
      expect(RemotePathUtil.sanitizeFileName('IMG_0001.JPG'), 'IMG_0001.jpg');
    });

    test('无扩展名', () {
      expect(RemotePathUtil.sanitizeFileName('照片'), '照片');
    });

    test('以点开头的隐藏文件', () {
      expect(RemotePathUtil.sanitizeFileName('.nomedia'), 'nomedia');
    });
  });

  group('folderSegments', () {
    test('替换日期与相册变量', () {
      final segments = RemotePathUtil.folderSegments(
        template: '{album}/{yyyy}/{MM}/{dd}',
        albumName: '相机',
        date: DateTime(2026, 3, 4),
      );
      expect(segments, ['相机', '2026', '03', '04']);
    });

    test('空模板使用默认模板', () {
      final segments = RemotePathUtil.folderSegments(
        template: '  ',
        albumName: 'Screenshots',
        date: DateTime(2025, 12, 31),
      );
      expect(segments,
          ['Screenshots', '2025', '12']);
    });

    test('yymmdd 变量', () {
      final segments = RemotePathUtil.folderSegments(
        template: '{album}/{yyyyMMdd}',
        albumName: 'a',
        date: DateTime(2026, 1, 2),
      );
      expect(segments, ['a', '20260102']);
    });
  });

  group('join', () {
    test('拼接并处理 . 与 ..', () {
      expect(RemotePathUtil.join(['a', '', 'b/../c']), 'a/c');
    });

    test('忽略空段与首尾斜杠', () {
      expect(RemotePathUtil.join(['/a/', '/b/']), 'a/b');
    });
  });

  group('dirname / basename', () {
    test('正常路径', () {
      expect(RemotePathUtil.dirname('/a/b/c.txt'), '/a/b');
      expect(RemotePathUtil.basename('/a/b/c.txt'), 'c.txt');
    });

    test('没有目录', () {
      expect(RemotePathUtil.dirname('c.txt'), '');
      expect(RemotePathUtil.basename('c.txt'), 'c.txt');
    });
  });

  group('uniqueFileName', () {
    test('不冲突时原样返回', () {
      expect(RemotePathUtil.uniqueFileName('a.jpg', {}), 'a.jpg');
    });

    test('冲突时追加序号并看小写', () {
      expect(RemotePathUtil.uniqueFileName('a.jpg', {'a.jpg'}), 'a (1).jpg');
      expect(
        RemotePathUtil.uniqueFileName('A.JPG', {'a.jpg', 'a (1).jpg'}),
        'A (2).jpg',
      );
    });

    test('无扩展名冲突', () {
      expect(RemotePathUtil.uniqueFileName('照片', {'照片'}), '照片 (1)');
    });
  });
}
