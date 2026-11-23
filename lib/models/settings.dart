import '../core/remote_path.dart';

/// 上传网络策略。
enum NetworkPolicy { wifiOnly, any }

extension NetworkPolicyX on NetworkPolicy {
  String get label => switch (this) {
        NetworkPolicy.wifiOnly => '仅 Wi-Fi',
        NetworkPolicy.any => 'Wi-Fi 与移动数据',
      };

  String get description => switch (this) {
        NetworkPolicy.wifiOnly => '只有连接到 Wi-Fi 时才上传，使用移动数据时自动暂停',
        NetworkPolicy.any => '允许使用移动数据上传（可能产生流量费用）',
      };
}

class AppSettings {
  AppSettings({
    this.networkPolicy = NetworkPolicy.wifiOnly,
    this.concurrency = 2,
    this.autoScanOnStart = true,
    this.folderTemplate = RemotePathUtil.defaultFolderTemplate,
    this.notifyOnComplete = true,
    this.minImageBytes = 0,
    this.skipHidden = true,
    this.lastStorageId,
  });

  NetworkPolicy networkPolicy;
  int concurrency;
  bool autoScanOnStart;
  String folderTemplate;
  bool notifyOnComplete;
  int minImageBytes;
  bool skipHidden;
  String? lastStorageId;

  AppSettings copy() => AppSettings(
        networkPolicy: networkPolicy,
        concurrency: concurrency,
        autoScanOnStart: autoScanOnStart,
        folderTemplate: folderTemplate,
        notifyOnComplete: notifyOnComplete,
        minImageBytes: minImageBytes,
        skipHidden: skipHidden,
        lastStorageId: lastStorageId,
      );

  Map<String, dynamic> toJson() => {
        'networkPolicy': networkPolicy.name,
        'concurrency': concurrency,
        'autoScanOnStart': autoScanOnStart,
        'folderTemplate': folderTemplate,
        'notifyOnComplete': notifyOnComplete,
        'minImageBytes': minImageBytes,
        'skipHidden': skipHidden,
        'lastStorageId': lastStorageId,
      };

  static AppSettings fromJson(Map<String, dynamic> json) => AppSettings(
        networkPolicy: NetworkPolicy.values.firstWhere(
          (e) => e.name == json['networkPolicy'],
          orElse: () => NetworkPolicy.wifiOnly,
        ),
        concurrency: ((json['concurrency'] as num?)?.toInt() ?? 2).clamp(1, 4),
        autoScanOnStart: json['autoScanOnStart'] as bool? ?? true,
        folderTemplate:
            '${json['folderTemplate'] ?? RemotePathUtil.defaultFolderTemplate}',
        notifyOnComplete: json['notifyOnComplete'] as bool? ?? true,
        minImageBytes: (json['minImageBytes'] as num?)?.toInt() ?? 0,
        skipHidden: json['skipHidden'] as bool? ?? true,
        lastStorageId: json['lastStorageId'] as String?,
      );
}
