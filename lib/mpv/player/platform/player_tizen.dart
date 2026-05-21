import 'dart:async';

import 'package:flutter/services.dart';

import '../../../media/media_display_criteria.dart';
import '../../../utils/app_logger.dart';
import '../../models.dart';
import '../player.dart';
import '../player_state.dart';
import '../player_stream_controllers.dart';
import '../player_streams.dart';
import '../video_rect_support.dart';

/// Tizen player backend using a native C# overlay player (TizenMediaPlayer.cs).
///
/// Replaces video_player_tizen's TBM-surface-through-Flutter-GPU approach with
/// Tizen's hardware compositor overlay (Display(MediaView)), which renders video
/// on a separate hardware plane and returns the GPU fully to the Flutter UI.
///
/// Video rect coordinates are sent to the native side whenever the widget layout
/// changes, so the MediaView tracks the Flutter widget's screen position.
class PlayerTizen with PlayerStreamControllersMixin implements Player, VideoRectSupport {
  static const _method = MethodChannel('com.plezy/tizen_player');
  static const _event = EventChannel('com.plezy/tizen_player/events');

  PlayerState _state = const PlayerState();
  late final PlayerStreams _streams;
  StreamSubscription<dynamic>? _eventSub;
  bool _disposed = false;
  bool _firstFrameFired = false;

  // Broadcasts native key names relayed from the ElmSharp video window.
  // Subscribers (VideoPlayerScreen) use this to handle back/d-pad while
  // the video window has Wayland keyboard focus.
  final _nativeKeyController = StreamController<String>.broadcast();
  Stream<String> get nativeKeyStream => _nativeKeyController.stream;

  // Throttle position updates to ~4Hz.
  final _throttleSw = Stopwatch()..start();
  int _lastPositionEmitMs = 0;

  // Populated on 'initialized' event — exposed for the performance overlay.
  int? videoWidth;
  int? videoHeight;
  String? videoCodec;
  String? audioCodec;
  int? audioSampleRate;
  int? audioChannels;
  String? decoderType;

  PlayerTizen() {
    _streams = createStreams();
    _eventSub = _event.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (e) {
        if (!_disposed) errorController.add(PlayerError(e.toString()));
      },
    );
  }

  @override
  PlayerState get state => _state;

  @override
  PlayerStreams get streams => _streams;

  @override
  int? get textureId => null; // video renders in native overlay, not Flutter texture

  @override
  bool get disposed => _disposed;

  @override
  String get playerType => 'tizen';

  @override
  bool get supportsSecondarySubtitles => false;

  // ── Event handling ────────────────────────────────────────────────────────

  void _handleEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final map = raw.cast<String, dynamic>();
    final event = map['event'] as String?;
    if (event == null) return;

    switch (event) {
      case 'initialized':
        final durationMs = map['durationMs'] as int? ?? 0;
        final width = map['width'] as int? ?? 0;
        final height = map['height'] as int? ?? 0;
        videoWidth = width > 0 ? width : null;
        videoHeight = height > 0 ? height : null;
        final rawVideoCodec = map['videoCodec'] as String? ?? '';
        final rawAudioCodec = map['audioCodec'] as String? ?? '';
        videoCodec = rawVideoCodec.isNotEmpty ? rawVideoCodec : null;
        audioCodec = rawAudioCodec.isNotEmpty ? rawAudioCodec : null;
        final sr = map['audioSampleRate'] as int? ?? 0;
        audioSampleRate = sr > 0 ? sr : null;
        final ch = map['audioChannels'] as int? ?? 0;
        audioChannels = ch > 0 ? ch : null;
        final rawDecoder = map['decoderType'] as String? ?? '';
        decoderType = rawDecoder.isNotEmpty ? rawDecoder : null;
        final dur = Duration(milliseconds: durationMs);
        _state = _state.copyWith(duration: dur, seekable: true, buffering: false);
        durationController.add(dur);
        seekableController.add(true);
        bufferingController.add(false);
        if (width > 0 && height > 0) {
          appLogger.d('PlayerTizen: initialized ${width}x$height dur=${durationMs}ms');
        }

      case 'position':
        final posMs = map['positionMs'] as int? ?? 0;
        final nowMs = _throttleSw.elapsedMilliseconds;
        if (nowMs - _lastPositionEmitMs >= 250) {
          _lastPositionEmitMs = nowMs;
          final pos = Duration(milliseconds: posMs);
          _state = _state.copyWith(position: pos);
          positionController.add(pos);
        }

      case 'playing':
        final isPlaying = map['isPlaying'] as bool? ?? false;
        _state = _state.copyWith(playing: isPlaying);
        playingController.add(isPlaying);
        if (isPlaying && !_firstFrameFired) {
          _firstFrameFired = true;
          playbackRestartController.add(null);
        }

      case 'buffering':
        final isBuffering = map['isBuffering'] as bool? ?? false;
        _state = _state.copyWith(buffering: isBuffering);
        bufferingController.add(isBuffering);

      case 'completed':
        _state = _state.copyWith(completed: true, playing: false);
        completedController.add(true);
        playingController.add(false);

      case 'nativeKey':
        final keyName = map['keyName'] as String?;
        if (keyName != null) _nativeKeyController.add(keyName);

      case 'error':
        final msg = map['message'] as String? ?? 'Unknown error';
        errorController.add(PlayerError(msg));
    }
  }

  // ── VideoRectSupport ──────────────────────────────────────────────────────

  /// Called by the Video widget whenever layout changes.
  /// Forwards the physical-pixel rect to the native MediaView.
  @override
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('setVideoRect', {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'devicePixelRatio': devicePixelRatio,
      });
    } catch (e) {
      appLogger.w('PlayerTizen: setVideoRect failed', error: e);
    }
  }

  // ── Player interface ──────────────────────────────────────────────────────

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
  }) async {
    if (_disposed) return;
    _firstFrameFired = false;

    // Reset state
    _state = const PlayerState();
    positionController.add(Duration.zero);
    durationController.add(Duration.zero);
    playingController.add(false);
    completedController.add(false);
    bufferingController.add(true);
    seekableController.add(false);

    try {
      await _method.invokeMethod<void>('open', {
        'url': media.uri,
        if (media.headers != null && media.headers!.isNotEmpty) 'headers': media.headers,
        if (media.start != null) 'startMs': media.start!.inMilliseconds,
        'play': play,
      });
    } catch (e) {
      _state = _state.copyWith(buffering: false);
      bufferingController.add(false);
      errorController.add(PlayerError('Failed to open media: $e'));
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('play');
    } catch (e) {
      appLogger.w('PlayerTizen: play failed', error: e);
    }
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('pause');
    } catch (e) {
      appLogger.w('PlayerTizen: pause failed', error: e);
    }
  }

  @override
  Future<void> playOrPause() async {
    if (_disposed) return;
    if (_state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('stop');
    } catch (e) {
      appLogger.w('PlayerTizen: stop failed', error: e);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('seek', {'positionMs': position.inMilliseconds});
    } catch (e) {
      appLogger.w('PlayerTizen: seek failed', error: e);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('setVolume', {'volume': volume});
      _state = _state.copyWith(volume: volume);
      volumeController.add(volume);
    } catch (e) {
      appLogger.w('PlayerTizen: setVolume failed', error: e);
    }
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('setRate', {'rate': rate});
      _state = _state.copyWith(rate: rate);
      rateController.add(rate);
    } catch (e) {
      appLogger.w('PlayerTizen: setRate failed', error: e);
    }
  }

  /// Cycle native display mode (0=stretch, 1=letterbox, 2=crop).
  Future<void> setNativeDisplayMode(int mode) async {
    if (_disposed) return;
    try {
      await _method.invokeMethod<void>('setDisplayMode', {'mode': mode});
    } catch (e) {
      appLogger.w('PlayerTizen: setDisplayMode failed', error: e);
    }
  }

  // ── No-ops for mpv-specific features ─────────────────────────────────────

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> command(List<String> args) async {}

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {}

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> selectSecondarySubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> addSubtitleTrack({required String uri, String? title, String? language, bool select = false}) async {}

  @override
  Future<void> setAudioDevice(AudioDevice device) async {}

  @override
  Future<void> setAudioPassthrough(bool enabled) async {}

  @override
  Future<void> setLogLevel(String level) async {}

  @override
  Future<void> setDisplayCriteria(MediaDisplayCriteria? criteria) async {}

  @override
  Future<void> configureSubtitleFonts() async {}

  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async => true;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<bool> setVideoFrameRate(double fps, int durationMs, {int extraDelayMs = 0}) async => false;

  @override
  Future<void> clearVideoFrameRate() async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> abandonAudioFocus() async {}

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    try {
      await _method.invokeMethod<void>('dispose');
    } catch (_) {}
    await _nativeKeyController.close();
    await closeStreamControllers();
  }
}
