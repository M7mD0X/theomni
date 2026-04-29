/// Barrel file for the services layer.
///
/// Import this single file to get every service + the agent contract:
///
/// ```dart
/// import 'package:theomni/services/services.dart';
/// ```
///
/// Existing code that imports individual files directly (e.g.
/// `agent_service.dart`) continues to work unchanged.

export 'agent/agent_interface.dart';
export 'agent/agent_launcher.dart';
export 'agent/agent_factory.dart';
export 'agent/cloud_agent_service.dart';
export 'agent/local_agent_service.dart';
export 'agent_service.dart';
export 'app_mode_service.dart';
export 'native_file_service.dart';
export 'settings_service.dart';
