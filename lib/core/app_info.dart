/// 应用元信息：版本号与仓库地址（发版时同步更新）。
class AppInfo {
  const AppInfo._();

  static const String version = '0.2.0';
  static const String buildNumber = '3';
  static const String repository = 'https://github.com/kirning/photo-sync';
  static const String appName = '照片同步';

  static String get versionLabel => '$version+$buildNumber';
}
