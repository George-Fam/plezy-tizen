import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../media/media_display_criteria.dart';
import '../../../utils/app_logger.dart';
import '../../models.dart';
import '../player.dart';
import '../player_state.dart';
import '../player_stream_controllers.dart';
import '../player_streams.dart';
import '../subtitle_stream_support.dart';
import '../video_rect_support.dart';

// Parsed subtitle cue.
typedef _SubCue = ({int startMs, int endMs, String text});

/// Tizen player backend using a native C# overlay player (TizenMediaPlayer.cs).
///
/// Replaces video_player_tizen's TBM-surface-through-Flutter-GPU approach with
/// Tizen's hardware compositor overlay (Display(MediaView)), which renders video
/// on a separate hardware plane and returns the GPU fully to the Flutter UI.
///
/// Video rect coordinates are sent to the native side whenever the widget layout
/// changes, so the MediaView tracks the Flutter widget's screen position.
class PlayerTizen with PlayerStreamControllersMixin implements Player, VideoRectSupport, SubtitleStreamSupport {
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

  // ── Track state ────────────────────────────────────────────────────────────
  // Capi-enumerated tracks (populated on 'initialized' event).
  List<AudioTrack> _capiAudioTracks = const [];
  List<SubtitleTrack> _capiSubtitleTracks = const [];
  // External (Dart-parsed) subtitle tracks, added via addSubtitleTrack().
  final List<SubtitleTrack> _dartSubtitleTracks = [];

  // ── Subtitle display (SubtitleStreamSupport) ───────────────────────────────
  // Cue lists keyed by URI, for Dart-parsed external subtitles.
  final _loadedSubtitles = <String, List<_SubCue>>{};
  List<_SubCue> _activeSubtitleCues = const [];
  // When true, subtitle text comes from C# SubtitleUpdated callback (embedded).
  // When false, it comes from the Dart position-based cue lookup (external).
  bool _embeddedSubtitleActive = false;
  // Stores the track that selectSubtitleTrack() wanted but couldn't activate
  // because addSubtitleTrack() hadn't finished the HTTP fetch yet.
  SubtitleTrack? _pendingSubtitleTrack;
  // Remembers the active track when sub-visibility:'no' hides it, so
  // sub-visibility:'yes' can restore it (mirrors Android's _hiddenSubtitleTrackId).
  SubtitleTrack? _hiddenSubtitleTrack;
  Timer? _embeddedSubtitleClearTimer;
  final _subtitleTextCtrl = StreamController<String>.broadcast();
  StreamSubscription<Duration>? _subtitlePositionSub;
  String _lastSubtitleText = '';

  @override
  Stream<String> get subtitleTextStream => _subtitleTextCtrl.stream;

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

        // Parse audio tracks from Capi player enumeration.
        _capiAudioTracks = _parseCapiAudioTracks(map['audioTracks']);
        // Parse embedded subtitle tracks.
        _capiSubtitleTracks = _parseCapiSubtitleTracks(map['embeddedSubtitleTracks']);
        _emitTracks();

        _state = _state.copyWith(duration: dur, seekable: true, buffering: false);
        durationController.add(dur);
        seekableController.add(true);
        bufferingController.add(false);
        if (width > 0 && height > 0) {
          appLogger.d('PlayerTizen: initialized ${width}x$height dur=${durationMs}ms '
              'audio=${_capiAudioTracks.length} sub=${_capiSubtitleTracks.length}');
        }

      case 'subtitle':
        // Embedded subtitle text from the Capi player's SubtitleUpdated callback.
        if (!_embeddedSubtitleActive) break;
        final text = map['text'] as String? ?? '';
        final durationMs2 = map['durationMs'] as int? ?? 3000;
        _embeddedSubtitleClearTimer?.cancel();
        _lastSubtitleText = text;
        if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add(text);
        if (text.isNotEmpty) {
          _embeddedSubtitleClearTimer = Timer(Duration(milliseconds: durationMs2), () {
            _lastSubtitleText = '';
            if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add('');
          });
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
        if (isPlaying) {
          // Fire on first play AND after every resume (mirrors mpv's
          // playback-restart which fires after seeks too). TrackManager
          // listens for this to clear waitingForExternalSubsTrackSelection.
          if (!_firstFrameFired) _firstFrameFired = true;
          playbackRestartController.add(null);
        }

      case 'buffering':
        final isBuffering = map['isBuffering'] as bool? ?? false;
        final percent = map['percent'] as int? ?? 0;
        // Approximate buffer duration from percent × total duration.
        final bufferDur = _state.duration > Duration.zero
            ? Duration(milliseconds: (_state.duration.inMilliseconds * percent / 100).round())
            : Duration.zero;
        _state = _state.copyWith(buffering: isBuffering, buffer: bufferDur);
        bufferingController.add(isBuffering);
        bufferController.add(bufferDur);

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
  /// Coordinates are already in physical pixels (logical × dpr done by the
  /// caller); SetRoi on the C# side uses them directly — no further scaling.
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
        // devicePixelRatio intentionally omitted: C# uses physical pixels directly.
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

    // Reset track and subtitle state for the new media item.
    _capiAudioTracks = const [];
    _capiSubtitleTracks = const [];
    _dartSubtitleTracks.clear();
    _loadedSubtitles.clear();
    _activeSubtitleCues = const [];
    _embeddedSubtitleActive = false;
    _pendingSubtitleTrack = null;
    _hiddenSubtitleTrack = null;
    _embeddedSubtitleClearTimer?.cancel();
    _embeddedSubtitleClearTimer = null;
    _subtitlePositionSub?.cancel();
    _subtitlePositionSub = null;
    _lastSubtitleText = '';
    if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add('');

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
      _state = _state.copyWith(seekable: false, playing: false, buffering: false);
      seekableController.add(false);
      bufferingController.add(false);
      playingController.add(false);
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
  Future<void> setProperty(String name, String value) async {
    switch (name) {
      // sub-visibility mirrors Android's _hiddenSubtitleTrackId pattern:
      // 'no' remembers and hides the current track; 'yes' restores it.
      case 'sub-visibility':
        if (value == 'no') {
          _hiddenSubtitleTrack = _state.track.subtitle;
          await selectSubtitleTrack(SubtitleTrack.off);
        } else {
          final hidden = _hiddenSubtitleTrack;
          if (hidden != null && hidden.id != 'no') {
            _hiddenSubtitleTrack = null;
            await selectSubtitleTrack(hidden);
          }
        }

      // Subtitle style properties (sub-font-size, sub-color, sub-bold, etc.)
      // are not actionable without changes to the shared subtitle overlay widget.
      // Silently ignore — the overlay uses hardcoded defaults.

      // All other properties (sub-delay, audio-delay, glsl-shaders, etc.)
      // are not implementable on Tizen — silently ignore.
      default:
        break;
    }
  }

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> command(List<String> args) async {
    if (args.isEmpty) return;
    if (args[0] == 'sub-seek' && args.length >= 2) {
      final offset = int.tryParse(args[1]) ?? 0;
      _handleSubSeek(offset);
    }
    // glsl-shaders, screenshot etc. are mpv-specific; no-op on Tizen.
  }

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    if (_disposed) return;
    if (!track.id.startsWith('capi_audio:')) return;
    final index = int.tryParse(track.id.replaceFirst('capi_audio:', ''));
    if (index == null) return;
    try {
      await _method.invokeMethod<void>('selectAudioTrack', {'index': index});
      _state = _state.copyWith(track: _state.track.copyWith(audio: track));
      trackController.add(_state.track);
    } catch (e) {
      appLogger.w('PlayerTizen: selectAudioTrack failed', error: e);
    }
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    _subtitlePositionSub?.cancel();
    _subtitlePositionSub = null;
    _embeddedSubtitleClearTimer?.cancel();
    _embeddedSubtitleClearTimer = null;

    if (track.id == 'no' || track.id == 'auto') {
      // Off — clear both paths.
      _embeddedSubtitleActive = false;
      _activeSubtitleCues = const [];
      _lastSubtitleText = '';
      if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add('');
      _state = _state.copyWith(track: _state.track.copyWith(subtitle: track));
      trackController.add(_state.track);
      return;
    }

    if (track.id.startsWith('capi_sub:')) {
      // Embedded subtitle — let C# SubtitleUpdated drive the display.
      final index = int.tryParse(track.id.replaceFirst('capi_sub:', ''));
      _embeddedSubtitleActive = true;
      _activeSubtitleCues = const [];
      _lastSubtitleText = '';
      if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add('');
      if (index != null) {
        try {
          await _method.invokeMethod<void>('selectSubtitleTrack', {'index': index});
        } catch (e) {
          appLogger.w('PlayerTizen: selectSubtitleTrack (capi) failed', error: e);
        }
      }
      _state = _state.copyWith(track: _state.track.copyWith(subtitle: track));
      trackController.add(_state.track);
      return;
    }

    if (track.isExternal && track.uri != null) {
      // External Dart-parsed subtitle.
      final cues = _loadedSubtitles[track.uri!];
      if (cues == null) {
        // Cues not ready yet — addSubtitleTrack() is still fetching.
        // Store as pending; it will be activated once loading completes.
        _pendingSubtitleTrack = track;
        appLogger.d('PlayerTizen: cues not ready for ${track.uri}, stored as pending');
        return;
      }
      _embeddedSubtitleActive = false;
      _activeSubtitleCues = cues;
      _subtitlePositionSub = _streams.position.listen(_onSubtitlePosition);
      _state = _state.copyWith(track: _state.track.copyWith(subtitle: track));
      trackController.add(_state.track);
    }
  }

  @override
  Future<void> selectSecondarySubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> addSubtitleTrack({required String uri, String? title, String? language, bool select = false}) async {
    try {
      final content = await _fetchText(uri);
      _loadedSubtitles[uri] = _parseSubtitle(content);
      appLogger.d('PlayerTizen: loaded ${_loadedSubtitles[uri]!.length} cues from $uri');

      // Register this as an available subtitle track so the track selection
      // system finds it in player.state.tracks.subtitle.
      final dartTrack = SubtitleTrack(
        id: 'external:$uri',
        title: title,
        language: language,
        codec: _inferSubtitleCodec(uri),
        isExternal: true,
        uri: uri,
      );
      if (!_dartSubtitleTracks.any((t) => t.uri == uri)) {
        _dartSubtitleTracks.add(dartTrack);
        _emitTracks();
      }

      if (select) {
        _embeddedSubtitleActive = false;
        _activeSubtitleCues = _loadedSubtitles[uri]!;
        _subtitlePositionSub?.cancel();
        _subtitlePositionSub = _streams.position.listen(_onSubtitlePosition);
        _state = _state.copyWith(track: _state.track.copyWith(subtitle: dartTrack));
        trackController.add(_state.track);
      }

      // If selectSubtitleTrack was called while this URI was still loading,
      // activate it now that cues are ready.
      final pending = _pendingSubtitleTrack;
      if (!select && pending != null && pending.uri == uri) {
        _pendingSubtitleTrack = null;
        _embeddedSubtitleActive = false;
        _activeSubtitleCues = _loadedSubtitles[uri]!;
        _subtitlePositionSub?.cancel();
        _subtitlePositionSub = _streams.position.listen(_onSubtitlePosition);
        _state = _state.copyWith(track: _state.track.copyWith(subtitle: pending));
        trackController.add(_state.track);
        appLogger.d('PlayerTizen: auto-activated pending subtitle $uri');
      }
    } catch (e) {
      appLogger.w('PlayerTizen: failed to load subtitle from $uri', error: e);
    }
  }

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
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async {
    if (_disposed) return true;
    try {
      await _method.invokeMethod<void>('setVisible', {'visible': visible});
    } catch (e) {
      appLogger.w('PlayerTizen: setVisible failed', error: e);
    }
    return true;
  }

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
    _embeddedSubtitleClearTimer?.cancel();
    await _subtitlePositionSub?.cancel();
    await _subtitleTextCtrl.close();
    await _eventSub?.cancel();
    try {
      await _method.invokeMethod<void>('dispose');
    } catch (_) {}
    await _nativeKeyController.close();
    await closeStreamControllers();
  }

  // ── Track helpers ─────────────────────────────────────────────────────────

  void _emitTracks() {
    final tracks = Tracks(
      audio: _capiAudioTracks,
      subtitle: [..._capiSubtitleTracks, ..._dartSubtitleTracks],
    );
    _state = _state.copyWith(tracks: tracks);
    tracksController.add(tracks);
  }

  List<AudioTrack> _parseCapiAudioTracks(dynamic raw) {
    if (raw is! List) return const [];
    final result = <AudioTrack>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final index = map['index'] as int? ?? result.length;
      final lang = map['language'] as String? ?? '';
      result.add(AudioTrack(
        id: 'capi_audio:$index',
        title: lang.isNotEmpty ? lang : 'Track ${index + 1}',
        language: lang.isNotEmpty ? lang : null,
      ));
    }
    return result;
  }

  List<SubtitleTrack> _parseCapiSubtitleTracks(dynamic raw) {
    if (raw is! List) return const [];
    final result = <SubtitleTrack>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final index = map['index'] as int? ?? result.length;
      final lang = map['language'] as String? ?? '';
      result.add(SubtitleTrack(
        id: 'capi_sub:$index',
        title: lang.isNotEmpty ? lang : 'Subtitle ${index + 1}',
        language: lang.isNotEmpty ? lang : null,
      ));
    }
    return result;
  }

  void _handleSubSeek(int offset) {
    if (_activeSubtitleCues.isEmpty) return;
    final posMs = _state.position.inMilliseconds;

    // Find current cue index, or the cue just before current position.
    int currentIndex = -1;
    for (int i = 0; i < _activeSubtitleCues.length; i++) {
      final cue = _activeSubtitleCues[i];
      if (posMs >= cue.startMs && posMs < cue.endMs) {
        currentIndex = i;
        break;
      }
      if (cue.startMs > posMs) {
        currentIndex = i - 1;
        break;
      }
    }

    final targetIndex = (currentIndex + offset).clamp(0, _activeSubtitleCues.length - 1);
    final targetMs = _activeSubtitleCues[targetIndex].startMs;
    seek(Duration(milliseconds: targetMs));
  }

  // ── Subtitle helpers ──────────────────────────────────────────────────────

  /// Infers subtitle codec from URI file extension, stripping query params first.
  static String? _inferSubtitleCodec(String uri) {
    final path = uri.toLowerCase().split('?').first;
    if (path.endsWith('.srt')) return 'srt';
    if (path.endsWith('.vtt') || path.endsWith('.webvtt')) return 'webvtt';
    if (path.endsWith('.ass') || path.endsWith('.ssa')) return 'ass';
    return null;
  }

  void _onSubtitlePosition(Duration pos) {
    if (_activeSubtitleCues.isEmpty) return;
    final posMs = pos.inMilliseconds;
    String text = '';
    for (final cue in _activeSubtitleCues) {
      if (posMs >= cue.startMs && posMs < cue.endMs) {
        text = cue.text;
        break;
      }
    }
    if (text != _lastSubtitleText) {
      _lastSubtitleText = text;
      if (!_subtitleTextCtrl.isClosed) _subtitleTextCtrl.add(text);
    }
  }

  /// Fetches text content from a file:// or HTTP URI.
  /// A 15-second timeout is applied to the connection and response so a stalled
  /// network doesn't leave the subtitle load suspended indefinitely.
  Future<String> _fetchText(String uri) async {
    if (uri.startsWith('file://')) {
      return File(uri.replaceFirst('file://', '')).readAsString();
    }
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(uri))
          .timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(const Duration(seconds: 15));
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  /// Dispatches to SRT or VTT parser based on content.
  List<_SubCue> _parseSubtitle(String content) {
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('WEBVTT')) return _parseVtt(content);
    return _parseSrt(content);
  }

  List<_SubCue> _parseSrt(String content) {
    final cues = <_SubCue>[];
    final lines = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final timingRe = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.:](\d{3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.:](\d{3})',
    );
    int i = 0;
    while (i < lines.length) {
      while (i < lines.length && lines[i].trim().isEmpty) i++;
      if (i >= lines.length) break;
      // Skip optional cue index line (all-digit)
      if (RegExp(r'^\d+$').hasMatch(lines[i].trim())) i++;
      if (i >= lines.length) break;
      final m = timingRe.firstMatch(lines[i]);
      if (m == null) { i++; continue; }
      final startMs = _tsToMs(m, 1);
      final endMs = _tsToMs(m, 5);
      i++;
      final textLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        textLines.add(lines[i]);
        i++;
      }
      if (textLines.isNotEmpty) {
        final text = textLines.join('\n').replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (text.isNotEmpty) cues.add((startMs: startMs, endMs: endMs, text: text));
      }
    }
    return cues;
  }

  List<_SubCue> _parseVtt(String content) {
    final cues = <_SubCue>[];
    final lines = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    // VTT timestamps use '.' as ms separator; same regex handles both ',' and '.'
    final timingRe = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})',
    );
    int i = 0;
    while (i < lines.length && !lines[i].contains('-->')) i++;
    while (i < lines.length) {
      final m = timingRe.firstMatch(lines[i]);
      if (m != null) {
        final startMs = _tsToMs(m, 1);
        final endMs = _tsToMs(m, 5);
        i++;
        final textLines = <String>[];
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          textLines.add(lines[i]);
          i++;
        }
        if (textLines.isNotEmpty) {
          final text = textLines.join('\n').replaceAll(RegExp(r'<[^>]*>'), '').trim();
          if (text.isNotEmpty) cues.add((startMs: startMs, endMs: endMs, text: text));
        }
      } else {
        i++;
      }
    }
    return cues;
  }

  static int _tsToMs(RegExpMatch m, int o) =>
      int.parse(m.group(o)!) * 3600000 +
      int.parse(m.group(o + 1)!) * 60000 +
      int.parse(m.group(o + 2)!) * 1000 +
      int.parse(m.group(o + 3)!);
}
