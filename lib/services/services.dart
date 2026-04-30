/// Barrel file for the services layer.
///
/// Import individual services directly for cleaner dependency graphs:
/// ```dart
/// import 'package:omni_ide/services/agent/agent_interface.dart';
/// import 'package:omni_ide/services/agent_service.dart';
/// ```

export 'agent/agent_interface.dart';
export 'agent/agent_launcher.dart';
export 'agent/agent_bootstrap.dart';
export 'agent/agent_factory.dart';
export 'agent/cloud_agent_service.dart';
export 'agent/local_agent_service.dart';
export 'agent/throttled_notifications.dart';
export 'agent_service.dart';
export 'app_mode_service.dart';
export 'native_file_service.dart';
export 'settings_service.dart';
export 'syntax_highlight_service.dart';
