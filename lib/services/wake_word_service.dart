import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:shared_preferences/shared_preferences.dart';

/// Always-on wake word: a tiny streaming keyword spotter that listens for
/// "SeeRuta" and then hands control to the SeeRuta Assistant.
///
/// mic (`record`, 16 kHz mono PCM16)
///   -> sherpa-onnx keyword spotter (zipformer transducer, 3M params, int8)
///   -> [onWake] once per detection
///
/// The model is the bilingual Chinese/English KWS export, because its English
/// keywords are phonemes from a pronunciation lexicon (`en.phone`) instead of
/// BPE pieces. That is what lets an invented word like "SeeRuta" be spelled
/// out exactly: `S IY1 R UW1 T AH0` = "see-roo-ta". The comparable
/// English-only (GigaSpeech) model can only spell keywords with its BPE
/// vocabulary and missed this one in testing.
///
/// Everything runs on-device. This is deliberately *not* whisper: decoding a
/// window every couple of seconds would keep a phone-class CPU busy and drain
/// the battery; the KWS model only runs its encoder on the newest audio chunk
/// and costs a few milliseconds per chunk.
///
/// The model files are copied out of assets into app storage on first use,
/// because sherpa-onnx takes file paths. The spotter itself stays in native
/// memory while the feature is enabled so re-arming after a command is quick;
/// [disable] releases it.
///
/// Lifecycle: while enabled the service keeps listening in the foreground and
/// suspends itself when the app goes to the background. The Home page pauses it
/// while the Assistant records (two `record` instances cannot own the mic) and
/// resumes it when the utterance is done.
class WakeWordService with WidgetsBindingObserver {
  WakeWordService._();

  /// One instance for the whole app: the setting outlives any single page.
  static final WakeWordService instance = WakeWordService._();

  /// Preference key shared with the Settings page toggle.
  static const String prefKey = 'seeRutaWakeWordEnabled';

  /// Keyword phrase lives in `assets/models/kws/keywords.txt` as phonemes, not
  /// here, so it can be tuned without touching Dart:
  /// `S IY1 R UW1 T AH0 @SeeRuta`.
  static const String _assetDir = 'assets/models/kws';

  /// Bundled model files and the smallest size that still means a complete
  /// copy (guards against a half-written file from an interrupted copy).
  static const Map<String, int> _assets = {
    'encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx': 4 * 1024 * 1024,
    'decoder-epoch-13-avg-2-chunk-16-left-64.onnx': 600 * 1024,
    'joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx': 60 * 1024,
    'tokens.txt': 1024,
    'keywords.txt': 4,
  };

  static const int sampleRate = 16000;

  /// Microphone format the spotter expects. `voiceRecognition` is Android's
  /// speech source: it avoids the AGC/noise-suppression pumping of `DEFAULT`
  /// that can swallow a quietly spoken wake word.
  static const RecordConfig _recordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: sampleRate,
    numChannels: 1,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceRecognition,
    ),
  );

  /// Retry delay after the platform closes the mic on its own (audio focus,
  /// route loss). Re-arming immediately would just fail again.
  static const Duration _restartDelay = Duration(seconds: 2);

  /// Give up re-arming after this many consecutive failures, so a device that
  /// refuses the mic cannot spin on it forever.
  static const int _maxRestarts = 3;

  /// User intent, persisted. Kept separate from [state] because the intent
  /// survives a temporary suspend (background, Assistant recording).
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// What the microphone is doing right now, for the Settings page.
  final ValueNotifier<WakeWordState> state =
      ValueNotifier<WakeWordState>(WakeWordState.off);

  /// Called once per detection, after the mic has been released. The Home page
  /// speaks "Listening" and starts the Assistant here.
  Future<void> Function()? onWake;

  final AudioRecorder _recorder = AudioRecorder();

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _restartTimer;

  bool _bindingsReady = false;
  bool _observing = false;
  bool _running = false;
  bool _starting = false;
  bool _wakeFired = false;
  int _restartCount = 0;

  /// Bumped on every teardown. A start that was in flight when the mic was
  /// taken away (Assistant tapped, feature disabled, app backgrounded) sees a
  /// changed value after its awaits and must not open the mic again.
  int _generation = 0;

  /// Reads the saved choice. Returns true when the wake word was enabled by
  /// the user in a previous session (the caller may then start listening).
  Future<bool> restore() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(prefKey) ?? false;
    if (enabled.value) _attachObserver();
    return enabled.value;
  }

  /// Turns the feature on (persisted) and starts listening, asking for the
  /// microphone permission when it has not been granted yet.
  ///
  /// Returns the state after the attempt. On failure the saved choice is
  /// rolled back, so a denied permission does not leave a toggle that claims
  /// to be on but can never work.
  Future<WakeWordState> enable() async {
    enabled.value = true;
    await _setPref(true);
    _attachObserver();
    if (!await start(askPermission: true)) {
      enabled.value = false;
      await _setPref(false);
      _detachObserverIfIdle();
    }
    return state.value;
  }

  /// Turns the feature off, releases the native spotter and forgets the
  /// choice.
  Future<void> disable() async {
    enabled.value = false;
    await _setPref(false);
    _restartTimer?.cancel();
    _restartTimer = null;
    await _teardown();
    _releaseSpotter();
    _detachObserverIfIdle();
    state.value = WakeWordState.off;
  }

  Future<void> _setPref(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, value);
    } catch (error) {
      debugPrint('WakeWordService preference write failed: $error');
    }
  }

  /// Starts listening. [askPermission] is false for resumes (background,
  /// after a command) so the OS prompt only ever appears on an explicit
  /// enable or on the first start of a saved choice.
  Future<bool> start({bool askPermission = true}) async {
    if (_running) return true;
    if (_starting) return false;
    _starting = true;
    final generation = ++_generation;
    state.value = WakeWordState.starting;
    try {
      final permission = askPermission
          ? await Permission.microphone.request()
          : await Permission.microphone.status;
      if (!permission.isGranted) {
        state.value = WakeWordState.permissionDenied;
        return false;
      }

      if (!await _prepareSpotter()) return false;
      if (generation != _generation) {
        // Suspended while the model was loading.
        state.value = WakeWordState.off;
        return false;
      }

      _stream = _spotter!.createStream();
      final audio = await _recorder.startStream(_recordConfig);
      if (generation != _generation) {
        // The mic was taken away while it was opening (Assistant tapped,
        // feature disabled, app backgrounded). Close it again.
        try {
          await _recorder.stop();
        } catch (_) {}
        _stream?.free();
        _stream = null;
        state.value = WakeWordState.off;
        return false;
      }
      _running = true;
      _audioSub = audio.listen(
        _onAudioChunk,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('Wake word mic error: $error');
          _scheduleRestart();
        },
        onDone: () {
          // The platform can end the capture on its own (audio focus taken,
          // route lost, app in the background). Re-arm instead of going deaf.
          if (_running) _scheduleRestart();
        },
        cancelOnError: true,
      );
      _wakeFired = false;
      _restartCount = 0;
      state.value = WakeWordState.listening;
      return true;
    } catch (error, stackTrace) {
      debugPrint('Wake word start failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await _teardown();
      state.value = WakeWordState.unavailable;
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Stops the microphone but keeps the user's choice, so [resume] can bring
  /// it back after the Assistant has finished recording.
  Future<void> suspend() async {
    if (!_running && !_starting && _stream == null) return;
    await _teardown();
    // Cancels a start that is still opening the mic, and clears the state for
    // the ones that had already finished starting.
    if (state.value != WakeWordState.permissionDenied &&
        state.value != WakeWordState.unavailable) {
      state.value = WakeWordState.off;
    }
  }

  /// Re-arms the wake word after a suspend, if the user still wants it.
  Future<void> resume() async {
    if (!enabled.value || _running || _starting) return;
    if (await Permission.microphone.status.isGranted) {
      await start(askPermission: false);
    }
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    // teardown leaves _running false, so guard against a late onDone.
    _running = false;
    unawaited(_restartAfterFailure());
  }

  Future<void> _restartAfterFailure() async {
    // Release the recorder before the retry, otherwise the next startStream
    // can race the stop that is still in flight.
    await _teardown();
    if (!enabled.value) return;
    if (++_restartCount > _maxRestarts) {
      state.value = WakeWordState.unavailable;
      return;
    }
    _restartTimer = Timer(_restartDelay, () => unawaited(resume()));
  }

  /// Feeds one PCM16 chunk to the streaming encoder and checks the decoder.
  void _onAudioChunk(Uint8List chunk) {
    final spotter = _spotter;
    final stream = _stream;
    if (!_running || spotter == null || stream == null) return;

    final samples = pcm16ToFloat32(chunk);
    if (samples.isEmpty) return;

    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      while (spotter.isReady(stream)) {
        spotter.decode(stream);
      }
      if (spotter.getResult(stream).keyword.isNotEmpty) _fireWake();
    } catch (error, stackTrace) {
      debugPrint('Wake word decode failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _scheduleRestart();
    }
  }

  /// Releases the mic *before* handing control to the Assistant (its recorder
  /// needs exclusive use of the microphone), then calls [onWake].
  void _fireWake() {
    if (_wakeFired) return;
    _wakeFired = true;
    final callback = onWake;
    scheduleMicrotask(() async {
      await _teardown();
      state.value = WakeWordState.off;
      try {
        await callback?.call();
      } catch (error, stackTrace) {
        debugPrint('Wake word handler failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    });
  }

  Future<void> _teardown() async {
    _generation++;
    _running = false;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (error) {
      debugPrint('Wake word recorder stop failed: $error');
    }
    _stream?.free();
    _stream = null;
  }

  /// Copies the model out of assets and creates the native spotter. Idempotent.
  Future<bool> _prepareSpotter() async {
    if (_spotter != null) return true;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/wake_word');
      if (!await dir.exists()) await dir.create(recursive: true);

      for (final entry in _assets.entries) {
        final file = File('${dir.path}/${entry.key}');
        if (await file.exists() && await file.length() >= entry.value) continue;
        final data = await rootBundle.load('$_assetDir/${entry.key}');
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }

      if (!_bindingsReady) {
        sherpa.initBindings();
        _bindingsReady = true;
      }

      _spotter = sherpa.KeywordSpotter(
        sherpa.KeywordSpotterConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder:
                  '${dir.path}/encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx',
              decoder:
                  '${dir.path}/decoder-epoch-13-avg-2-chunk-16-left-64.onnx',
              joiner:
                  '${dir.path}/joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx',
            ),
            tokens: '${dir.path}/tokens.txt',
            // One thread is plenty for a 3.3M-parameter model and leaves the
            // other cores to the map.
            numThreads: 1,
            provider: 'cpu',
            debug: false,
          ),
          keywordsFile: '${dir.path}/keywords.txt',
        ),
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('Wake word model failed to load: $error');
      debugPrintStack(stackTrace: stackTrace);
      state.value = WakeWordState.unavailable;
      return false;
    }
  }

  void _releaseSpotter() {
    _spotter?.free();
    _spotter = null;
  }

  // ---- App lifecycle --------------------------------------------------------

  void _attachObserver() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void _detachObserverIfIdle() {
    if (!_observing || enabled.value || _running) return;
    WidgetsBinding.instance.removeObserver(this);
    _observing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(resume());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // No microphone in the background: it is a privacy indicator and a
        // battery cost with nothing on screen to explain it.
        unawaited(suspend());
      case AppLifecycleState.inactive:
        // Transient (notification shade, permission dialog): keep listening.
        break;
    }
  }

  /// Converts little-endian PCM16 bytes to the [-1, 1] floats sherpa-onnx
  /// feature extraction expects. Pure so it can be unit tested.
  static Float32List pcm16ToFloat32(Uint8List chunk) {
    final count = chunk.lengthInBytes ~/ 2;
    if (count == 0) return Float32List(0);
    final data = ByteData.sublistView(chunk, 0, count * 2);
    final samples = Float32List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }

  /// Releases everything. Only for tests and app shutdown; the Home page keeps
  /// the singleton alive so the Assistant can resume it after each command.
  Future<void> dispose() async {
    enabled.value = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _teardown();
    _releaseSpotter();
    _detachObserverIfIdle();
    await _recorder.dispose();
    state.value = WakeWordState.off;
    state.dispose();
    enabled.dispose();
  }
}

/// What the wake word engine is doing.
enum WakeWordState {
  /// Not listening (disabled, paused for a command, or in the background).
  off,

  /// Loading the model and opening the mic.
  starting,

  /// Armed; waiting for "SeeRuta".
  listening,

  /// The microphone permission is missing or was denied.
  permissionDenied,

  /// The model or the recorder could not start.
  unavailable,
}
