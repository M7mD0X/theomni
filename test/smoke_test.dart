import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_ide/services/agent_service.dart';
import 'package:omni_ide/services/app_mode_service.dart';
import 'package:omni_ide/services/settings_service.dart';
import 'package:omni_ide/widgets/editor_view.dart';

void main() {
  // ── 1. AgentMessage ──────────────────────────────────────────────────────
  group('AgentMessage', () {
    test('stores role, text, and sets time to now', () {
      final before = DateTime.now();
      final msg = AgentMessage(role: 'user', text: 'Hello');
      final after = DateTime.now();

      expect(msg.role, 'user');
      expect(msg.text, 'Hello');
      expect(msg.time.isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue);
      expect(msg.time.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('meta defaults to null', () {
      final msg = AgentMessage(role: 'agent', text: 'Hi');
      expect(msg.meta, isNull);
    });

    test('accepts optional meta map', () {
      final meta = {'key': 'value', 'count': 42};
      final msg = AgentMessage(
        role: 'tool_call',
        text: 'read_file',
        meta: meta,
      );

      expect(msg.role, 'tool_call');
      expect(msg.text, 'read_file');
      expect(msg.meta, isNotNull);
      expect(msg.meta!['key'], 'value');
      expect(msg.meta!['count'], 42);
    });

    test('supports all documented roles', () {
      for (final role in [
        'user',
        'agent',
        'system',
        'tool_call',
        'tool_result',
        'error',
      ]) {
        final msg = AgentMessage(role: role, text: 'test');
        expect(msg.role, role);
      }
    });
  });

  // ── 2. SettingsService constants ─────────────────────────────────────────
  group('SettingsService', () {
    test('providers contains expected keys', () {
      expect(SettingsService.providers.containsKey('openrouter'), isTrue);
      expect(SettingsService.providers.containsKey('anthropic'), isTrue);
      expect(SettingsService.providers.containsKey('openai'), isTrue);
      expect(SettingsService.providers.containsKey('custom'), isTrue);
    });

    test('providers maps to human-readable names', () {
      expect(SettingsService.providers['openrouter'], 'OpenRouter');
      expect(SettingsService.providers['anthropic'], 'Claude (Anthropic)');
      expect(SettingsService.providers['openai'], 'OpenAI');
      expect(SettingsService.providers['custom'], 'Custom API');
    });

    test('providers has exactly 4 entries', () {
      expect(SettingsService.providers.length, 4);
    });

    test('baseUrls contains expected provider endpoints', () {
      expect(
          SettingsService.baseUrls['openrouter'], 'https://openrouter.ai/api/v1');
      expect(SettingsService.baseUrls['anthropic'], 'https://api.anthropic.com');
      expect(SettingsService.baseUrls['openai'], 'https://api.openai.com/v1');
    });

    test('baseUrls has entries for the 3 built-in providers', () {
      expect(SettingsService.baseUrls.length, 3);
      expect(SettingsService.baseUrls.containsKey('custom'), isFalse);
    });
  });

  // ── 3. OpenFile ──────────────────────────────────────────────────────────
  group('OpenFile', () {
    test('stores path, name, and content', () {
      final file = OpenFile(
        path: '/home/user/project/main.dart',
        name: 'main.dart',
        content: 'void main() {}',
      );

      expect(file.path, '/home/user/project/main.dart');
      expect(file.name, 'main.dart');
      expect(file.content, 'void main() {}');
    });

    test('content is mutable', () {
      final file = OpenFile(
        path: '/tmp/test.txt',
        name: 'test.txt',
        content: 'original',
      );

      expect(file.content, 'original');
      file.content = 'modified';
      expect(file.content, 'modified');
    });

    test('path and name are immutable final fields', () {
      final file = OpenFile(
        path: '/a/b.dart',
        name: 'b.dart',
        content: '',
      );
      // These should not be reassignable — verified at compile time by `final`.
      expect(file.path, '/a/b.dart');
      expect(file.name, 'b.dart');
    });
  });

  // ── 4. WelcomeView widget ───────────────────────────────────────────────
  group('WelcomeView', () {
    testWidgets('renders without crashing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WelcomeView()),
        ),
      );

      // If we reach here without an exception, the widget rendered.
      expect(find.byType(WelcomeView), findsOneWidget);
    });

    testWidgets('contains expected welcome text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WelcomeView()),
        ),
      );

      expect(find.text('a pocket-sized'), findsOneWidget);
      expect(find.textContaining('development'), findsWidgets);
    });

    testWidgets('displays hint rows with labels', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WelcomeView()),
        ),
      );

      expect(find.text('open a file'), findsOneWidget);
      expect(find.text('ask the agent'), findsOneWidget);
      expect(find.text('configure keys'), findsOneWidget);
    });

    testWidgets('has a dot-grid background painter', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WelcomeView()),
        ),
      );

      // The background uses a CustomPaint with _DotGrid.
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  // ── 5. AppMode enum ─────────────────────────────────────────────────────
  group('AppMode', () {
    test('has cloud and local values', () {
      expect(AppMode.values, contains(AppMode.cloud));
      expect(AppMode.values, contains(AppMode.local));
    });

    test('has exactly two values', () {
      expect(AppMode.values.length, 2);
    });

    test('can be compared for equality', () {
      expect(AppMode.cloud, equals(AppMode.cloud));
      expect(AppMode.local, equals(AppMode.local));
      expect(AppMode.cloud, isNot(equals(AppMode.local)));
    });

    test('enum index is stable', () {
      expect(AppMode.cloud.index, 0);
      expect(AppMode.local.index, 1);
    });

    test('enum name is readable', () {
      expect(AppMode.cloud.name, 'cloud');
      expect(AppMode.local.name, 'local');
    });
  });

  // ── 6. AgentState enum (bonus) ──────────────────────────────────────────
  group('AgentState', () {
    test('has expected state values', () {
      expect(AgentState.values.length, 4);
      expect(AgentState.values, containsAll([
        AgentState.disconnected,
        AgentState.connecting,
        AgentState.connected,
        AgentState.thinking,
      ]));
    });

    test('state order is disconnected → connecting → connected → thinking', () {
      expect(AgentState.disconnected.index, 0);
      expect(AgentState.connecting.index, 1);
      expect(AgentState.connected.index, 2);
      expect(AgentState.thinking.index, 3);
    });
  });
}
