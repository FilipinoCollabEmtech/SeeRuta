import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/assistant_service.dart';
import '../services/wake_word_service.dart';

/// Settings page, opened from the burger menu dropdown on Home.
///
/// Holds the Accessibility section with the SeeRuta Assistant toggle, which
/// shows the mic button on Home. Turning the toggle on speaks a confirmation
/// through the speaker (audio-first for blind users); the choice is persisted
/// with shared_preferences so it survives restarts.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SharedPreferences? _prefs;
  bool _assistantEnabled = false;
  bool _wakeWordEnabled = false;
  bool _loaded = false;
  FlutterTts? _tts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tts?.stop();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final assistant =
        prefs.getBool(AssistantService.assistantPrefKey) ?? false;
    final wake = prefs.getBool(WakeWordService.prefKey) ?? false;
    setState(() {
      _prefs = prefs;
      _assistantEnabled = assistant;
      // The wake word cannot run without the Assistant; do not show a switch
      // as on when nothing is listening behind it.
      _wakeWordEnabled = assistant && wake;
      _loaded = true;
    });
    if (!assistant && wake) {
      // Saved while the Assistant was on, then the Assistant was turned off
      // elsewhere: forget the choice so the state cannot come back stale.
      unawaited(WakeWordService.instance.disable());
    }
  }

  /// Lazily builds the TTS engine used for toggle confirmations, mirroring
  /// the Assistant's voice settings.
  Future<FlutterTts?> _ensureTts() async {
    if (_tts != null) return _tts;
    try {
      final tts = FlutterTts();
      await tts.setLanguage('en-US');
      await tts.setSpeechRate(AssistantService.speechRate);
      _tts = tts;
    } catch (_) {
      _tts = null; // TTS unavailable: the SnackBar still confirms.
    }
    return _tts;
  }

  Future<void> _toggleAssistant(bool value) async {
    setState(() => _assistantEnabled = value);
    await _prefs?.setBool(AssistantService.assistantPrefKey, value);
    // The wake word is only meaningful with the Assistant behind it.
    if (!value && _wakeWordEnabled) {
      setState(() => _wakeWordEnabled = false);
      await WakeWordService.instance.disable();
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              value
                  ? 'SeeRuta Assistant enabled. Find the mic button on Home.'
                  : 'SeeRuta Assistant disabled.',
            ),
          ),
        );
    }
    // Audio-first: confirm out loud so blind users know the toggle took.
    final tts = await _ensureTts();
    await tts?.speak(
      value ? 'SeeRuta Assistant enabled' : 'SeeRuta Assistant disabled',
    );
  }

  /// Arms the always-listening "SeeRuta" detector. Turning it on is the
  /// moment the microphone permission is requested (if it is not granted
  /// yet); a refusal rolls the toggle back instead of leaving it dead on.
  Future<void> _toggleWakeWord(bool value) async {
    setState(() => _wakeWordEnabled = value);
    final tts = await _ensureTts();

    if (!value) {
      await WakeWordService.instance.disable();
      _showMessage('Wake word off.');
      await tts?.speak('Wake word off');
      return;
    }

    final state = await WakeWordService.instance.enable();
    if (!mounted) return;
    final listening = state == WakeWordState.listening;
    if (!listening) setState(() => _wakeWordEnabled = false);

    final message = switch (state) {
      WakeWordState.listening =>
        'Wake word on. Say SeeRuta to open the microphone.',
      WakeWordState.permissionDenied =>
        'Microphone permission is needed for the wake word.',
      _ => 'The wake word could not start on this device.',
    };
    _showMessage(message);

    // The confirmation is spoken through the speaker, and the spotter is now
    // listening: release the mic first so it cannot hear us say "SeeRuta"
    // and wake the Assistant on its own. Do not put the wake phrase in the
    // spoken confirmation for the same reason.
    await WakeWordService.instance.suspend();
    await tts?.speak(listening ? 'Wake word on' : message);
    if (listening) await WakeWordService.instance.resume();
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Accessibility', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('SeeRuta Assistant'),
              subtitle:
                  const Text('Voice commands on the Home mic — English and Cebuano, offline'),
              value: _assistantEnabled,
              onChanged: _loaded ? _toggleAssistant : null,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              secondary: const Icon(Icons.graphic_eq),
              title: const Text('Wake word “SeeRuta”'),
              subtitle: const Text(
                'Listens while the app is open. Say SeeRuta to wake the '
                'Assistant.',
              ),
              value: _wakeWordEnabled,
              onChanged:
                  _loaded && _assistantEnabled ? _toggleWakeWord : null,
            ),
          ),
        ],
      ),
    );
  }
}
