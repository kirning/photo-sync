import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/models/storage_config.dart';
import 'package:photo_sync/remote/aws_sigv4.dart';
import 'package:photo_sync/remote/options.dart';
import 'package:photo_sync/remote/remote_storage.dart';
import 'package:photo_sync/remote/s3_storage.dart';

/// 构造一份 S3 配置，字段按需覆盖。
StorageConfig _config([Map<String, dynamic> overrides = const {}]) =>
    StorageConfig(
      id: 's3-test',
      name: 'S3 测试',
      type: StorageType.s3,
      fields: <String, dynamic>{
        'endpoint': 'https://s3.example.com',
        'bucket': 'photo-bucket',
        'accessKey': 'AKIATEST',
        'secretKey': 'secret',
        'region': 'us-east-1',
        'root': '',
        'pathStyle': true,
        ...overrides,
      },
      createdAt: DateTime(2024, 1, 1),
    );

S3Options _options([Map<String, dynamic> overrides = const {}]) =>
    S3Options.from(_config(overrides));

void main() {
  group('S3Options URL 构建', () {
    test('path-style：bucket 在路径上，中文与空格只编码一次', () {
      final options = _options({'root': '备份/2024', 'pathStyle': true});
      final url = options.uriFor('我的 相册/a b.jpg');

      expect(url.scheme, 'https');
      expect(url.host, 's3.example.com');
      expect(
        url.toString(),
        'https://s3.example.com/photo-bucket/%E5%A4%87%E4%BB%BD/2024/'
        '%E6%88%91%E7%9A%84%20%E7%9B%B8%E5%86%8C/a%20b.jpg',
      );
      // 不能出现二次编码。
      expect(url.toString(), isNot(contains('%2520')));
      expect(url.toString(), isNot(contains('%25E4')));
      // Uri.path 是已编码的路径，pathSegments 才是解码后的分段。
      expect(
        url.pathSegments.join('/'),
        'photo-bucket/备份/2024/我的 相册/a b.jpg',
      );
    });

    test('virtual-host：bucket 在域名上，保留自定义端口', () {
      final options = _options({
        'endpoint': 'https://s3.example.com:9443',
        'root': 'photos',
        'pathStyle': false,
      });
      final url = options.uriFor('a b.jpg');

      expect(url.host, 'photo-bucket.s3.example.com');
      expect(url.port, 9443);
      expect(
        url.toString(),
        'https://photo-bucket.s3.example.com:9443/photos/a%20b.jpg',
      );
      expect(url.toString(), isNot(contains('%2520')));
      expect(options.hostHeader(url), 'photo-bucket.s3.example.com:9443');
    });

    test('path-style：空 root 时 bucket 根 URL', () {
      final options = _options({'pathStyle': true});
      expect(
        options.uriFor('').toString(),
        'https://s3.example.com/photo-bucket',
      );
      expect(options.uriFor('').pathSegments, <String>['photo-bucket']);
    });

    test('virtual-host：空 root 时 bucket 根 URL', () {
      final options = _options({'pathStyle': false});
      expect(
        options.uriFor('').toString(),
        'https://photo-bucket.s3.example.com/',
      );
      expect(options.uriFor('').path, '/');
    });

    test('root 会规范化：去掉首尾斜杠与空段', () {
      final options = _options({'root': '/备份//2024/'});
      expect(options.root, '备份/2024');
      expect(options.keyFor('a.jpg'), '备份/2024/a.jpg');
    });

    test('query 参数：编码一次且能解码回原值', () {
      final options = _options();
      final url = options.uriFor('', query: {
        'prefix': '照片 2024/',
        'list-type': '2',
        'max-keys': '1000',
      });

      expect(url.queryParameters['list-type'], '2');
      expect(url.queryParameters['max-keys'], '1000');
      expect(url.queryParameters['prefix'], '照片 2024/');
      expect(url.toString(), isNot(contains('%2520')));
      expect(url.toString(), isNot(contains('%25E7')));
    });
  });

  group('AwsSigV4', () {
    const credentials = AwsCredentials(
      accessKey: 'AKIAIOSFODNN7EXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    );
    const emptySha256 =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('空串与示例 payload 的 sha256 常量', () {
      expect(AwsSigV4.sha256HexOfString(''), emptySha256);
      expect(AwsSigV4.sha256Hex(const <int>[]), emptySha256);
      // 来源：AWS S3 API Reference - Signature Version 4，Example: PUT Object
      // 的 payload = "Welcome to Amazon S3."，已用独立实现复算。
      expect(
        AwsSigV4.sha256HexOfString('Welcome to Amazon S3.'),
        '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
      );
    });

    test('awsEncode 只保留非保留字符，斜杠可选', () {
      expect(AwsSigV4.awsEncode('Az09-_.~'), 'Az09-_.~');
      expect(AwsSigV4.awsEncode('/'), '%2F');
      expect(AwsSigV4.awsEncode('/a b', encodeSlash: false), '/a%20b');
      expect(AwsSigV4.awsEncode('中文'), '%E4%B8%AD%E6%96%87');
      // 已编码的输入会被再次编码，调用方必须传解码后的文本。
      expect(AwsSigV4.awsEncode('%20'), '%2520');
    });

    test('canonicalUri 逐段编码并保留分隔斜杠', () {
      expect(
        AwsSigV4.canonicalUri('/a b/中文.jpg'),
        '/a%20b/%E4%B8%AD%E6%96%87.jpg',
      );
      expect(AwsSigV4.canonicalUri('a b'), '/a%20b');
      expect(AwsSigV4.canonicalUri('/'), '/');
    });

    test('canonicalQuery 按 key 排序并编码', () {
      final query = AwsSigV4.canonicalQuery({
        'prefix': '照片 2024/',
        'max-keys': '1000',
        'list-type': '2',
        'continuation-token': 'a+b/c=',
      });
      expect(
        query,
        'continuation-token=a%2Bb%2Fc%3D&list-type=2&max-keys=1000&'
        'prefix=%E7%85%A7%E7%89%87%202024%2F',
      );
    });

    test('相同输入签名稳定，Authorization 结构正确', () {
      final url = Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt');

      Map<String, String> sign() => AwsSigV4.sign(
            method: 'GET',
            url: url,
            headers: const {'range': 'bytes=0-9'},
            payloadHash: emptySha256,
            credentials: credentials,
            region: 'us-east-1',
            service: 's3',
            timestamp: DateTime.utc(2013, 5, 24),
          );

      final first = sign();
      final second = sign();
      expect(first['Authorization'], second['Authorization']);
      expect(first['x-amz-date'], '20130524T000000Z');
      expect(first['x-amz-content-sha256'], emptySha256);

      final authorization = first['Authorization']!;
      expect(
        authorization,
        startsWith(
          'AWS4-HMAC-SHA256 '
          'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
          'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
          'Signature=',
        ),
      );
      expect(
        RegExp(r'Signature=[0-9a-f]{64}$').hasMatch(authorization),
        isTrue,
        reason: '签名应为 64 位小写十六进制',
      );
    });

    // 来源：AWS S3 API Reference - Signature Version 4，Example: GET Object。
    // 期望值已用独立实现（Python hmac + hashlib）复算一致。
    test('AWS 官方测试向量：GET Object', () {
      final headers = AwsSigV4.sign(
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: const {'range': 'bytes=0-9'},
        payloadHash: emptySha256,
        credentials: credentials,
        region: 'us-east-1',
        service: 's3',
        timestamp: DateTime.utc(2013, 5, 24),
      );
      expect(
        headers['Authorization']!.split('Signature=').last,
        'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
      expect(
        headers['Authorization'],
        contains('SignedHeaders=host;range;x-amz-content-sha256;x-amz-date'),
      );
    });

    test('payload hash 参与签名', () {
      final url = Uri.parse(
        'https://examplebucket.s3.amazonaws.com/test%24file.text',
      );
      Map<String, String> signWith(String payloadHash) => AwsSigV4.sign(
            method: 'PUT',
            url: url,
            headers: const {
              'date': 'Fri, 24 May 2013 00:00:00 GMT',
              'x-amz-storage-class': 'REDUCED_REDUNDANCY',
            },
            payloadHash: payloadHash,
            credentials: credentials,
            region: 'us-east-1',
            service: 's3',
            timestamp: DateTime.utc(2013, 5, 24),
          );

      final first = signWith(emptySha256);
      final second = signWith(
        AwsSigV4.sha256HexOfString('Welcome to Amazon S3.'),
      );
      expect(first['x-amz-content-sha256'], emptySha256);
      expect(first['Authorization'], isNot(second['Authorization']));
      expect(
        first['Authorization'],
        contains('SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;'
            'x-amz-storage-class'),
      );
    });

    test('临时凭证会附带 x-amz-security-token 并参与签名', () {
      final headers = AwsSigV4.sign(
        method: 'GET',
        url: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
        headers: const {},
        payloadHash: emptySha256,
        credentials: const AwsCredentials(
          accessKey: 'AKIATEST',
          secretKey: 'secret',
          sessionToken: 'session-token',
        ),
        region: 'us-east-1',
        service: 's3',
        timestamp: DateTime.utc(2013, 5, 24),
      );
      expect(headers['x-amz-security-token'], 'session-token');
      expect(
        headers['Authorization'],
        contains('x-amz-security-token'),
      );
    });
  });

  group('S3Storage', () {
    test('ensureDir 直接返回（对象存储无目录）', () async {
      final storage = S3Storage(_config());
      await storage.ensureDir('DCIM/2024/05');
      await storage.close();
    });

    test('公开路径参数相对 root，内部用 resolve 拼对象 Key', () {
      final storage = S3Storage(_config({'root': 'photos'}));
      expect(storage.resolve('DCIM/a.jpg'), 'photos/DCIM/a.jpg');
      expect(storage.resolve('/DCIM/a.jpg'), 'photos/DCIM/a.jpg');
    });

    test('配置缺失时 open 抛中文 RemoteException', () async {
      final storage = S3Storage(_config({'endpoint': '', 'bucket': ''}));
      await expectLater(
        storage.open(),
        throwsA(
          isA<RemoteException>().having(
            (error) => error.message,
            'message',
            contains('S3 Endpoint'),
          ),
        ),
      );
      await storage.close();
    });

    test('open 后可重复 close', () async {
      final storage = S3Storage(_config());
      await storage.open();
      await storage.close();
      await storage.close();
    });

    test('上传前检查本地文件是否存在（不联网）', () async {
      final storage = S3Storage(_config());
      final missing = File(
        '${Directory.systemTemp.path}/photo-sync-s3-missing-'
        '${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await expectLater(
        storage.uploadOnce(missing, 'DCIM/missing.jpg'),
        throwsA(
          isA<RemoteException>().having(
            (error) => error.message,
            'message',
            contains('本地文件不存在'),
          ),
        ),
      );
      await storage.close();
    });
  });
}
