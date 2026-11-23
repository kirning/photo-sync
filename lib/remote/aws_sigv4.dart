import 'dart:convert';

import 'package:crypto/crypto.dart';

class AwsCredentials {
  const AwsCredentials({
    required this.accessKey,
    required this.secretKey,
    this.sessionToken,
  });

  final String accessKey;
  final String secretKey;
  final String? sessionToken;

  bool get isComplete => accessKey.isNotEmpty && secretKey.isNotEmpty;
}

/// AWS Signature Version 4 签名实现（仅 S3 所需部分）。
///
/// 参考：Amazon S3 API Reference - Signature Version 4 (Header-based auth)。
class AwsSigV4 {
  const AwsSigV4._();

  static const String algorithm = 'AWS4-HMAC-SHA256';

  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String sha256HexOfString(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// AWS 规范的 URI 编码：保留 A-Z a-z 0-9 - _ . ~，其余按 %XX 大写。
  static String awsEncode(String value, {bool encodeSlash = true}) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final isUnreserved = (byte >= 65 && byte <= 90) || // A-Z
          (byte >= 97 && byte <= 122) || // a-z
          (byte >= 48 && byte <= 57) || // 0-9
          byte == 45 || // -
          byte == 46 || // .
          byte == 95 || // _
          byte == 126; // ~
      if (isUnreserved) {
        buffer.writeCharCode(byte);
      } else if (byte == 47 && !encodeSlash) {
        buffer.write('/');
      } else {
        buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return buffer.toString();
  }

  /// 规范化的对象路径：逐段编码，保留 `/`。
  static String canonicalUri(String path) {
    final segments = path.split('/');
    final encoded = segments.map((e) => awsEncode(e)).join('/');
    return encoded.startsWith('/') ? encoded : '/$encoded';
  }

  /// 规范化查询串：按 key 排序，键值都做 AWS 编码。
  static String canonicalQuery(Map<String, String?> query) {
    if (query.isEmpty) return '';
    final keys = query.keys.toList()..sort();
    return keys
        .map((key) => '${awsEncode(key)}=${awsEncode(query[key] ?? '')}')
        .join('&');
  }

  static String canonicalHeaders(Map<String, String> headers) {
    final keys = headers.keys.map((e) => e.toLowerCase()).toList()..sort();
    return keys.map((key) {
      final value = headers.entries
          .firstWhere((e) => e.key.toLowerCase() == key)
          .value
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      return '$key:$value\n';
    }).join();
  }

  static String signedHeaders(Map<String, String> headers) {
    final keys = headers.keys.map((e) => e.toLowerCase()).toList()..sort();
    return keys.join(';');
  }

  static String buildCanonicalRequest({
    required String method,
    required String canonicalUri,
    required String canonicalQueryString,
    required String canonicalHeadersString,
    required String signedHeadersString,
    required String payloadHash,
  }) {
    return '$method\n$canonicalUri\n$canonicalQueryString\n'
        '$canonicalHeadersString\n$signedHeadersString\n$payloadHash';
  }

  static String buildStringToSign({
    required DateTime timestamp,
    required String region,
    required String service,
    required String canonicalRequest,
  }) {
    final date = amzDate(timestamp);
    final dateStamp = date.substring(0, 8);
    final scope = '$dateStamp/$region/$service/aws4_request';
    return '$algorithm\n$date\n$scope\n${sha256HexOfString(canonicalRequest)}';
  }

  static String amzDate(DateTime timestamp) {
    final utc = timestamp.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
        'T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static List<int> signingKey({
    required String secretKey,
    required String dateStamp,
    required String region,
    required String service,
  }) {
    final kDate = Hmac(sha256, utf8.encode('AWS4$secretKey')).convert(utf8.encode(dateStamp)).bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode(service)).bytes;
    return Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
  }

  static String signature({
    required String secretKey,
    required String dateStamp,
    required String region,
    required String service,
    required String stringToSign,
  }) {
    final key = signingKey(
      secretKey: secretKey,
      dateStamp: dateStamp,
      region: region,
      service: service,
    );
    return Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();
  }

  /// 返回需要附加到请求上的头（含 Authorization、x-amz-date）。
  static Map<String, String> sign({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required String payloadHash,
    required AwsCredentials credentials,
    required String region,
    required String service,
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    final date = amzDate(now);
    final dateStamp = date.substring(0, 8);

    final allHeaders = <String, String>{
      for (final entry in headers.entries) entry.key: entry.value,
    };
    final defaultPort = url.scheme == 'https' ? 443 : 80;
    allHeaders['host'] = url.port == defaultPort ? url.host : '${url.host}:${url.port}';
    allHeaders['x-amz-date'] = date;
    allHeaders['x-amz-content-sha256'] = payloadHash;
    if (credentials.sessionToken != null && credentials.sessionToken!.isNotEmpty) {
      allHeaders['x-amz-security-token'] = credentials.sessionToken!;
    }

    final canonicalUriValue = canonicalUri(url.path.isEmpty ? '/' : url.path);
    final canonicalQueryValue = canonicalQuery(
      url.queryParametersAll.map((k, v) => MapEntry(k, v.isEmpty ? '' : v.first)),
    );
    final canonicalHeadersValue = canonicalHeaders(allHeaders);
    final signedHeadersValue = signedHeaders(allHeaders);
    final canonicalRequest = buildCanonicalRequest(
      method: method.toUpperCase(),
      canonicalUri: canonicalUriValue,
      canonicalQueryString: canonicalQueryValue,
      canonicalHeadersString: canonicalHeadersValue,
      signedHeadersString: signedHeadersValue,
      payloadHash: payloadHash,
    );
    final stringToSign = buildStringToSign(
      timestamp: now,
      region: region,
      service: service,
      canonicalRequest: canonicalRequest,
    );
    final sig = signature(
      secretKey: credentials.secretKey,
      dateStamp: dateStamp,
      region: region,
      service: service,
      stringToSign: stringToSign,
    );
    final scope = '$dateStamp/$region/$service/aws4_request';
    return {
      'x-amz-date': date,
      'x-amz-content-sha256': payloadHash,
      if (credentials.sessionToken != null && credentials.sessionToken!.isNotEmpty)
        'x-amz-security-token': credentials.sessionToken!,
      'Authorization':
          '$algorithm Credential=${credentials.accessKey}/$scope, '
              'SignedHeaders=$signedHeadersValue, Signature=$sig',
    };
  }
}
