/// Agent factory — creates the appropriate agent service based on mode.

import 'agent_interface.dart';
import 'cloud_agent_service.dart';
import 'local_agent_service.dart';
import '../app_mode_service.dart';
import '../settings_service.dart';

class AgentFactory {
  /// Create the right agent service for the current mode.
  ///
  /// - [AppMode.cloud] → [CloudAgentService] (direct API calls, no agent needed)
  /// - [AppMode.local] → [LocalAgentService] (WebSocket to on-device agent)
  static AgentServiceInterface create(
    AppModeService mode,
    SettingsService settings,
  ) {
    switch (mode.mode) {
      case AppMode.cloud:
        return CloudAgentService(settings);
      case AppMode.local:
        return LocalAgentService(settings);
    }
  }
}
