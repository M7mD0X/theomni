import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'theme/omni_theme.dart';
import 'services/agent_service.dart';
import 'services/app_mode_service.dart';
import 'screens/main_ide_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  final modeService = AppModeService();
  await modeService.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: modeService),
        ChangeNotifierProvider(create: (_) => AgentService(modeService)),
      ],
      child: const OmniApp(),
    ),
  );
}

class OmniApp extends StatelessWidget {
  const OmniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Omni-IDE',
      debugShowCheckedModeBanner: false,
      theme: T.theme,
      home: const _LaunchGate(),
    );
  }
}

/// Runs the first-launch storage permission + workspace creation step.
class _LaunchGate extends StatefulWidget {
  const _LaunchGate();
  @override
  State<_LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<_LaunchGate> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final mode = context.read<AppModeService>();
    if (!mode.firstLaunchDone) {
      // Best-effort: ask once, create the OmniIDE folder, then move on.
      final hasPerm = await mode.hasStoragePermission();
      if (!hasPerm) {
        await mode.requestStoragePermission();
      }
      await mode.ensureWorkspace();
      await mode.markFirstLaunchDone();
    } else {
      // Re-create folder in case the user deleted it.
      await mode.ensureWorkspace();
    }
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: T.bg,
        body: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: T.accent,
            ),
          ),
        ),
      );
    }
    return const MainIDEScreen();
  }
}
