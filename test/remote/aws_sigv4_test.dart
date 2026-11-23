import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/remote/aws_sigv4.dart';

void main() {
  group('awsEncode', () {
    test('保留未保留字符', () {
      expect(AwsSigV4.awsEncode('abcXYZ0189-_.~'), 'abcXYZ0189-_.~');
    });

    test('编码空格与中文', () {
      expect(AwsSigV4.awsEncode('a b'), 'a%20b');
      expect(AwsSigV4.awsEncode('照片'), '%E7%85%A7%E7%89%87');
    });

    test('默认编码斜杠', () {
      expect(AwsSigV4.awsEncode('a/b'), 'a%2Fb');
      expect(AwsSigV4.awsEncode('a/b', encodeSlash: false), 'a/b');
    });
  });

  group('canonicalUri', () {
    test('逐段编码并保留分隔符', () {
      expect(AwsSigV4.canonicalUri('/photo/2026/我的照片 1.jpg'),
          '/photo/2026/%E6%88%91%E7%9A%84%E7%85%A7%E7%89%87%201.jpg');
    });

    test('自动补前导斜杠', () {
      expect(AwsSigV4.canonicalUri('a/b'), '/a/b');
    });
  });

  group('canonicalQuery', () {
    test('按 key 排序并编码', () {
      expect(
        AwsSigV4.canonicalQuery({'prefix': 'a b', 'list-type': '2'}),
        'list-type=2&prefix=a%20b',
      );
    });

    test('空 map', () {
      expect(AwsSigV4.canonicalQuery({}), '');
    });
  });

  group('sign', () {
    test('生成带作用域与签名头的 Authorization', () {
      final credentials = AwsCredentials(
        accessKey: 'AKIDEXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      );
      final headers = AwsSigV4.sign(
        method: 'GET',
        url: Uri.parse('https://example.amazonaws.com/'),
        headers: const {'host': 'example.amazonaws.com'},
        payloadHash:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        credentials: credentials,
        region: 'us-east-1',
        service: 'service',
        timestamp: DateTime.utc(2015, 8, 30, 12, 36),
      );
      expect(headers['x-amz-date'], '20150830T123600Z');
      expect(
        headers['x-amz-content-sha256'],
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      final authorization = headers['Authorization']!;
      expect(authorization, startsWith('AWS4-HMAC-SHA256 Credential='));
      expect(authorization, contains('/20150830/us-east-1/service/aws4_request'));
      expect(
        authorization,
        contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'),
      );
      expect(
        RegExp(r'Signature=[0-9a-f]{64}$').hasMatch(authorization),
        isTrue,
        reason: authorization,
      );
    });

    test('同样的输入产生同样的签名', () {
      Map<String, String> run() => AwsSigV4.sign(
            method: 'PUT',
            url: Uri.parse('https://bucket.s3.amazonaws.com/dir/a.jpg'),
            headers: const {'content-type': 'image/jpeg'},
            payloadHash: AwsSigV4.sha256HexOfString('payload'),
            credentials: const AwsCredentials(accessKey: 'AK', secretKey: 'SK'),
            region: 'us-east-1',
            service: 's3',
            timestamp: DateTime.utc(2026, 5, 6, 7, 8, 9),
          );
      expect(run()['Authorization'], run()['Authorization']);
    });

    test('不同内容产生不同签名', () {
      Map<String, String> run(String payload) => AwsSigV4.sign(
            method: 'PUT',
            url: Uri.parse('https://bucket.s3.amazonaws.com/a.jpg'),
            headers: const {},
            payloadHash: AwsSigV4.sha256HexOfString(payload),
            credentials: const AwsCredentials(accessKey: 'AK', secretKey: 'SK'),
            region: 'us-east-1',
            service: 's3',
            timestamp: DateTime.utc(2026, 5, 6, 7, 8, 9),
          );
      expect(run('a')['Authorization'], isNot(run('b')['Authorization']));
    });

    test('签名包含会话令牌', () {
      final headers = AwsSigV4.sign(
        method: 'PUT',
        url: Uri.parse('https://bucket.s3.amazonaws.com/a.jpg'),
        headers: const {},
        payloadHash: AwsSigV4.sha256HexOfString(''),
        credentials: const AwsCredentials(
          accessKey: 'AK',
          secretKey: 'SK',
          sessionToken: 'TOKEN',
        ),
        region: 'ap-east-1',
        service: 's3',
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      expect(headers['x-amz-security-token'], 'TOKEN');
      expect(headers['x-amz-date'], '20260102T030405Z');
      expect(headers['Authorization'], contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token'));
    });

    test('非默认端口写进 host 头', () {
      // host 头只出现在 canonical headers 里，不返回给调用方；
      // 用不同端口的签名差异间接验证端口参与了签名。
      Map<String, String> run(int port) => AwsSigV4.sign(
            method: 'GET',
            url: Uri.parse('http://s3.example.com:$port/bucket'),
            headers: const {},
            payloadHash: AwsSigV4.sha256HexOfString(''),
            credentials: const AwsCredentials(accessKey: 'AK', secretKey: 'SK'),
            region: 'us-east-1',
            service: 's3',
            timestamp: DateTime.utc(2026, 1, 1),
          );
      expect(run(80)['Authorization'], isNot(run(9000)['Authorization']));
      expect(run(80)['Authorization'], isNot(run(8080)['Authorization']));
    });

    test('sha256 空串', () {
      expect(
        AwsSigV4.sha256HexOfString(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });
}
