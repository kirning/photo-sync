import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/app_info.dart';
import 'core/app_log.dart';
import 'core/crash_log.dart';
import 'data/app_paths.dart';
import 'data/app_repository.dart';
import 'services/background_service.dart';
import 'state/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final root = await getApplicationSupportDirectory();
  // 尽早安装异常捕获，后续任何未捕获异常都会写进 crash.log。
  await CrashLog.init(root);

  final paths = AppPaths(root);
  await paths.ensureDirectories();

  try {
    await initBackgroundService();
  } catch (error, stack) {
    AppLog.instance.error('bg', '后台服务初始化失败：$error', stack);
  }

  final state = AppState(paths: paths, repo: AppRepository(paths));
  await state.init();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const PhotoSyncApp(),
    ),
  );
}

class PhotoSyncApp extends StatelessWidget {
  const PhotoSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
