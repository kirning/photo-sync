import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/models/storage_config.dart';
import 'package:photo_sync/remote/options.dart';
import 'package:photo_sync/remote/smb_storage.dart';

StorageConfig _config(Map<String, dynamic> fields) {
  return StorageConfig(
    id: 'smb-test',
    name: '测试 SMB',
    type: StorageType.smb,
    fields: fields,
    createdAt: DateTime(2024, 1, 1),
  );
}

Map<String, dynamic> _smbFields({
  String host = 'nas.local',
  String share = 'public',
  String root = '',
  String username = 'user',
  String password = 'pass',
}) {
  return <String, dynamic>{
    'host': host,
    'share': share,
    'root': root,
    'username': username,
    'password': password,
  };
}

void main() {
  group('SmbOptions.fullPath', () {
    test('root 为空时只有共享名', () {
      final options = SmbOptions.from(_config(_smbFields()));
      expect(options.fullPath(''), '/public');
      expect(options.fullPath('a.jpg'), '/public/a.jpg');
      expect(options.fullPath('DCIM/2024/05/IMG_0001.jpg'),
          '/public/DCIM/2024/05/IMG_0001.jpg');
    });

    test('多级 root 会拼在共享名之后', () {
      final options = SmbOptions.from(
        _config(_smbFields(root: 'photos/2024')),
      );
      expect(options.root, 'photos/2024');
      expect(options.fullPath(''), '/public/photos/2024');
      expect(options.fullPath('05/a.jpg'), '/public/photos/2024/05/a.jpg');
    });

    test('root 里的反斜杠与首尾斜杠会被规范化', () {
      final options = SmbOptions.from(
        _config(_smbFields(root: '\\\\photos\\\\2024\\\\')),
      );
      expect(options.root, 'photos/2024');
      expect(options.fullPath('a.jpg'), '/public/photos/2024/a.jpg');
    });

    test('中文目录与文件名原样保留', () {
      final options = SmbOptions.from(
        _config(_smbFields(root: '照片/旅行')),
      );
      expect(options.fullPath('海边.jpg'), '/public/照片/旅行/海边.jpg');
      expect(options.fullPath('子目录/合影(1).jpg'),
          '/public/照片/旅行/子目录/合影(1).jpg');
    });

    test('相对路径里的 . 与 .. 会被清理', () {
      final options = SmbOptions.from(
        _config(_smbFields(root: 'photos')),
      );
      expect(options.fullPath('./a/../b.jpg'), '/public/photos/b.jpg');
    });

    test('host 支持 smb:// 前缀，DOMAIN\\user 会拆出域', () {
      final options = SmbOptions.from(
        _config(
          _smbFields(host: 'smb://nas.local/', username: r'WORKGROUP\alice'),
        ),
      );
      expect(options.host, 'nas.local');
      expect(options.domain, 'WORKGROUP');
      expect(options.username, 'alice');
    });

    test('share 的斜杠会被去掉', () {
      final options = SmbOptions.from(
        _config(_smbFields(share: '/共享 目录/')),
      );
      expect(options.share, '共享 目录');
      expect(options.fullPath('a.jpg'), '/共享 目录/a.jpg');
    });
  });

  group('SmbStorage.pathSegments', () {
    test('普通绝对路径', () {
      expect(
        SmbStorage.pathSegments('/public/照片/2024/05/a.jpg'),
        <String>['public', '照片', '2024', '05', 'a.jpg'],
      );
    });

    test('反斜杠、重复斜杠与 . 会被忽略', () {
      expect(
        SmbStorage.pathSegments(r'\public\\photos\.\a.jpg'),
        <String>['public', 'photos', 'a.jpg'],
      );
    });

    test('空路径与根路径没有片段', () {
      expect(SmbStorage.pathSegments(''), isEmpty);
      expect(SmbStorage.pathSegments('/'), isEmpty);
      expect(SmbStorage.pathSegments(r'\\'), isEmpty);
    });

    test('不解析 ..（由 RemotePathUtil.join 负责）', () {
      expect(
        SmbStorage.pathSegments('/public/a/../b.jpg'),
        <String>['public', 'a', '..', 'b.jpg'],
      );
    });
  });

  group('SmbStorage.parentPath', () {
    test('多级目录返回上一级', () {
      expect(
        SmbStorage.parentPath('/public/照片/2024/a.jpg'),
        '/public/照片/2024',
      );
      expect(SmbStorage.parentPath('/public/照片'), '/public');
    });

    test('共享根与文件系统根的父路径都是 /', () {
      expect(SmbStorage.parentPath('/public'), '/');
      expect(SmbStorage.parentPath('/'), '/');
      expect(SmbStorage.parentPath(''), '/');
    });

    test('末尾斜杠不影响结果', () {
      expect(SmbStorage.parentPath('/public/照片/2024/'), '/public/照片');
    });
  });

  group('SmbStorage.baseName', () {
    test('返回最后一段', () {
      expect(SmbStorage.baseName('/public/照片/a.jpg'), 'a.jpg');
      expect(SmbStorage.baseName(r'\public\照片\a.jpg'), 'a.jpg');
    });

    test('根路径返回空串', () {
      expect(SmbStorage.baseName('/'), '');
      expect(SmbStorage.baseName(''), '');
    });
  });
}
