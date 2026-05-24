using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Timers;
using ElmSharp;
using Tizen.Flutter.Embedding;
using Tizen.Multimedia;

// EFL P/Invoke for making the video window transparent to all input events.
// An empty Wayland input region causes keyboard/pointer events to fall through
// to Flutter's DALi window instead of being consumed by the video window.
internal static class WlInput
{
    [DllImport("libevas.so.1")]
    internal static extern IntPtr evas_object_evas_get(IntPtr obj);

    [DllImport("libecore_evas.so.1")]
    internal static extern IntPtr ecore_evas_ecore_evas_get(IntPtr e);

    [DllImport("libecore_evas.so.1")]
    internal static extern IntPtr ecore_evas_wayland2_window_get(IntPtr ee);

    // Setting w=0, h=0 creates an empty region — the window receives no input.
    [DllImport("libecore_wl2.so.1")]
    internal static extern void ecore_wl2_window_input_region_set(IntPtr win, int x, int y, int w, int h);
}

namespace Runner
{
    /// <summary>
    /// Native Tizen media player that renders video via Tizen's hardware compositor
    /// overlay instead of Flutter's GPU texture system.
    ///
    /// video_player_tizen uses PLAYER_DISPLAY_TYPE_NONE and passes every decoded frame
    /// through Flutter's GPU compositor via TBM surfaces. On a Mali-G52 with 4K content
    /// this saturates the GPU, leaving ~10fps for the Flutter UI.
    ///
    /// This implementation uses Display(NUI.Window) + DisplaySettings.SetRoi() which
    /// routes video through Tizen's hardware video plane — completely separate from
    /// Flutter's render pipeline — giving the GPU back to the UI.
    /// </summary>
    internal class TizenMediaPlayer : IEventStreamHandler, IDisposable
    {
        private readonly ElmSharp.Window _videoWindow;
        // SynchronizationContext captured on the main thread in Setup() so we
        // can post back to it from timer/player callbacks (thread-pool threads).
        private SynchronizationContext _mainContext;
        private Player _player;
        private IEventSink _eventSink;
        private System.Timers.Timer _positionTimer;
        private bool _disposed;
        private bool _isSeeking;
        private int _pendingSeekMs = -1;
        private int _openGeneration;
        private PlayerDisplayMode _currentDisplayMode = PlayerDisplayMode.FullScreen;

        public TizenMediaPlayer(ElmSharp.Window videoWindow)
        {
            _videoWindow = videoWindow;
        }

        public void Setup()
        {
            // Capture the platform (main) thread's SynchronizationContext here —
            // Setup() is called from App.OnCreate() which runs on the main thread.
            _mainContext = SynchronizationContext.Current ?? new SynchronizationContext();

            var methodChannel = new MethodChannel("com.plezy/tizen_player");
            methodChannel.SetMethodCallHandler(HandleMethodCall);

            var eventChannel = new EventChannel("com.plezy/tizen_player/events");
            eventChannel.SetStreamHandler(this);
        }

        // ── Method channel handler ───────────────────────────────────────────

        private async Task<object> HandleMethodCall(MethodCall call)
        {
            // Flutter's StandardMethodCodec serializes Dart Maps as Hashtable on C#.
            // Cast to non-generic IDictionary so string keys resolve correctly.
            var args = call.Arguments as System.Collections.IDictionary;
            switch (call.Method)
            {
                case "open":
                    await OpenAsync(args);
                    return null;

                case "play":
                    Play();
                    return null;

                case "pause":
                    Pause();
                    return null;

                case "stop":
                    Stop();
                    return null;

                case "seek":
                    await SeekAsync(Convert.ToInt32(args?["positionMs"]));
                    return null;

                case "setVolume":
                    SetVolume(Convert.ToDouble(args?["volume"]));
                    return null;

                case "setRate":
                    SetRate(Convert.ToDouble(args?["rate"]));
                    return null;

                case "setVideoRect":
                    SetVideoRect(args);
                    return null;

                case "setDisplayMode":
                    SetDisplayMode(Convert.ToInt32(args?["mode"] ?? call.Arguments));
                    return null;

                case "selectAudioTrack":
                    SelectAudioTrack(Convert.ToInt32(args?["index"]));
                    return null;

                case "selectSubtitleTrack":
                    SelectSubtitleTrack(Convert.ToInt32(args?["index"]));
                    return null;

                case "setVisible":
                    SetVisible(Convert.ToBoolean(args?["visible"]));
                    return null;

                case "dispose":
                    DisposePlayer();
                    return null;

                default:
                    throw new MissingPluginException();
            }
        }

        // ── Open ─────────────────────────────────────────────────────────────

        private async Task OpenAsync(System.Collections.IDictionary args)
        {
            var gen = ++_openGeneration;
            DisposePlayer();

            var url = args?["url"] as string;
            if (string.IsNullOrEmpty(url))
            {
                Post(() => _eventSink?.Success(ErrorEvent("open", "url is null or empty")));
                return;
            }

            _player = new Player();

            // Use NUI.Window directly — Display(Tizen.NUI.Window) is a supported ctor.
            // SetRoi positions the video within the window matching the Flutter widget.
            if (_videoWindow != null)
            {
                try
                {
                    // Display(ElmSharp.Window) uses the correct EWL handle format
                    // for player_set_display(OVERLAY) — avoids the raw P/Invoke handle
                    // mismatch that caused EINVAL with our previous attempts.
                    _player.Display = new Display(_videoWindow);
                    _player.DisplaySettings.Mode = PlayerDisplayMode.FullScreen;
                    _player.DisplaySettings.IsVisible = true;
                    _videoWindow.Show();
                    _videoWindow.Lower(); // below Flutter's DALi window

                    // Empty input region → all normal key/pointer events fall through
                    // to Flutter's DALi window (which has Wayland keyboard focus).
                    SetEmptyInputRegion();

                    // XF86Back is a privileged Tizen TV key — the system intercepts it
                    // before the Wayland compositor delivers it to the focused window.
                    // KeyGrab routes it exclusively to this EFL window regardless of
                    // focus, bypassing the system intercept. We relay it to Flutter via
                    // the event channel. AllowFocus is no longer called, so EFL delivers
                    // key events to this window normally.
                    _videoWindow.KeyGrab("XF86Back", false);
                    _videoWindow.KeyGrab("Back", false);
                    _videoWindow.KeyDown += OnVideoWindowKeyDown;
                    Log("Player display set via ElmSharp.Window");
                }
                catch (Exception e)
                {
                    Log($"Display setup failed: {e.Message}", isError: true);
                }
            }
            else
            {
                Log("Video window unavailable — video overlay disabled", isError: true);
            }

            // Player events fire on native threads — dispatch directly to the
            // EFL main loop (same thread Flutter's platform channels run on).
            _player.PlaybackCompleted += (s, e) =>
                Post(() =>
                    _eventSink?.Success(new Dictionary<string, object> { ["event"] = "completed" }));

            _player.SubtitleUpdated += (s, e) =>
                Post(() =>
                    _eventSink?.Success(new Dictionary<string, object>
                    {
                        ["event"] = "subtitle",
                        ["text"] = e.Text ?? "",
                        ["durationMs"] = (int)e.Duration,
                    }));

            _player.BufferingProgressChanged += (s, e) =>
                Post(() =>
                    _eventSink?.Success(new Dictionary<string, object>
                    {
                        ["event"] = "buffering",
                        ["isBuffering"] = e.Percent < 100,
                        ["percent"] = e.Percent,
                    }));

            _player.ErrorOccurred += (s, e) =>
                Post(() =>
                    _eventSink?.Success(ErrorEvent("playback", e.Error.ToString())));

            // HTTP headers: Cookie and UserAgent are properties on Player.
            if (args?["headers"] is System.Collections.IDictionary headers)
                ApplyHttpHeaders(headers);

            _player.SetSource(new MediaUriSource(url));

            try
            {
                await _player.PrepareAsync();
            }
            catch (Exception e)
            {
                Post(() => _eventSink?.Success(ErrorEvent("prepare", e.Message)));
                return;
            }

            // A newer open() call arrived while PrepareAsync was awaited — discard.
            if (gen != _openGeneration) return;

            int durationMs = _player.StreamInfo.GetDuration();
            int width = 0, height = 0;
            int audioSampleRate = 0, audioChannels = 0;
            string videoCodec = null, audioCodec = null, decoderType = null;
            try
            {
                var vp = _player.StreamInfo.GetVideoProperties();
                width = vp.Size.Width;
                height = vp.Size.Height;
                videoCodec = _player.StreamInfo.GetVideoCodec();
                audioCodec = _player.StreamInfo.GetAudioCodec();

                var ap = _player.StreamInfo.GetAudioProperties();
                audioSampleRate = ap.SampleRate;
                audioChannels = ap.Channels;

                // AudioCodecType tells us whether the decoder is hardware or software.
                decoderType = _player.AudioCodecType == CodecType.Hardware ? "Hardware" : "Software";
            }
            catch { }

            // Enumerate audio and embedded subtitle tracks via PlayerTrackInfo.
            var audioTracks = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
            var embeddedSubtitleTracks = new System.Collections.Generic.List<System.Collections.Generic.Dictionary<string, object>>();
            // PlayerTrackInfo exposes no Count — enumerate by index until GetLanguageCode throws.
            // PlayerTrackInfo exposes no Count — enumerate by index until GetLanguageCode throws.
            try
            {
                var info = _player.AudioTrackInfo;
                int current = info.Selected;
                for (int i = 0; i < 32; i++)
                {
                    string lang;
                    try { lang = info.GetLanguageCode(i) ?? ""; }
                    catch { break; }
                    audioTracks.Add(new System.Collections.Generic.Dictionary<string, object>
                    {
                        ["index"] = i,
                        ["language"] = lang,
                        ["isDefault"] = i == current,
                    });
                }
            }
            catch { }
            try
            {
                var info = _player.SubtitleTrackInfo;
                int current = info.Selected;
                for (int i = 0; i < 32; i++)
                {
                    string lang;
                    try { lang = info.GetLanguageCode(i) ?? ""; }
                    catch { break; }
                    embeddedSubtitleTracks.Add(new System.Collections.Generic.Dictionary<string, object>
                    {
                        ["index"] = i,
                        ["language"] = lang,
                        ["isDefault"] = i == current,
                    });
                }
            }
            catch { }

            Post(() => _eventSink?.Success(new Dictionary<string, object>
            {
                ["event"] = "initialized",
                ["durationMs"] = durationMs,
                ["width"] = width,
                ["height"] = height,
                ["videoCodec"] = videoCodec ?? "",
                ["audioCodec"] = audioCodec ?? "",
                ["audioSampleRate"] = audioSampleRate,
                ["audioChannels"] = audioChannels,
                ["decoderType"] = decoderType ?? "",
                ["audioTracks"] = audioTracks,
                ["embeddedSubtitleTracks"] = embeddedSubtitleTracks,
            }));

            // System.Timers.Timer runs on the thread pool. _eventSink.Success()
            // is called from the Elapsed handler; pending events from player
            // native callbacks are also drained there via _pendingEvents queue.
            _positionTimer = new System.Timers.Timer(250);
            _positionTimer.Elapsed += OnPositionTick;
            _positionTimer.AutoReset = true;
            _positionTimer.Start();

            var autoPlay = args["play"] != null && Convert.ToBoolean(args["play"]);
            if (autoPlay) Play();
        }

        private void ApplyHttpHeaders(System.Collections.IDictionary headers)
        {
            try
            {
                if (headers["Cookie"] is string cookieStr)
                    _player.Cookie = cookieStr;
                if (headers["User-Agent"] is string uaStr)
                    _player.UserAgent = uaStr;
            }
            catch (Exception e)
            {
                Log($"{e.Message}", isError: true);
            }
        }

        // ── Track selection ──────────────────────────────────────────────────

        private void SelectAudioTrack(int index)
        {
            try { _player.AudioTrackInfo.Selected = index; }
            catch (Exception e) { Log($"SelectAudioTrack failed: {e.Message}", isError: true); }
        }

        private void SelectSubtitleTrack(int index)
        {
            try { _player.SubtitleTrackInfo.Selected = index; }
            catch (Exception e) { Log($"SelectSubtitleTrack failed: {e.Message}", isError: true); }
        }

        // ── Visibility ───────────────────────────────────────────────────────

        private void SetVisible(bool visible)
        {
            if (_videoWindow == null) return;
            try
            {
                if (visible)
                {
                    _videoWindow.Show();
                    _videoWindow.Lower();
                    SetEmptyInputRegion();
                }
                else
                {
                    _videoWindow.Hide();
                }
            }
            catch (Exception e) { Log($"SetVisible failed: {e.Message}", isError: true); }
        }

        // ── Position timer ───────────────────────────────────────────────────

        private void OnPositionTick(object source, ElapsedEventArgs e)
        {
            Post(() =>
            {
                if (_disposed) return;

                try
                {
                    var state = _player?.State;
                    if (state == PlayerState.Playing || state == PlayerState.Paused)
                    {
                        _eventSink?.Success(new Dictionary<string, object>
                        {
                            ["event"] = "position",
                            ["positionMs"] = _player.GetPlayPosition(),
                        });
                    }
                }
                catch { }
            });
        }

        // ── Playback control ─────────────────────────────────────────────────

        private void Play()
        {
            try
            {
                var state = _player?.State;
                if (state == PlayerState.Ready || state == PlayerState.Paused)
                {
                    _player.Start();
                    _eventSink?.Success(new Dictionary<string, object>
                    {
                        ["event"] = "playing",
                        ["isPlaying"] = true,
                    });
                }
            }
            catch (Exception e) { Log($"{e.Message}", isError: true); }
        }

        private void Pause()
        {
            try
            {
                if (_player?.State == PlayerState.Playing)
                {
                    _player.Pause();
                    _eventSink?.Success(new Dictionary<string, object>
                    {
                        ["event"] = "playing",
                        ["isPlaying"] = false,
                    });
                }
            }
            catch (Exception e) { Log($"{e.Message}", isError: true); }
        }

        private void Stop()
        {
            try
            {
                var state = _player?.State;
                if (state == PlayerState.Playing || state == PlayerState.Paused)
                {
                    _player.Stop();
                    _eventSink?.Success(new Dictionary<string, object>
                    {
                        ["event"] = "playing",
                        ["isPlaying"] = false,
                    });
                }
            }
            catch (Exception e) { Log($"{e.Message}", isError: true); }
        }

        private async Task SeekAsync(int positionMs)
        {
            // Always record the latest requested position.
            _pendingSeekMs = positionMs;

            // If a seek is already running, let it finish and it will pick up
            // _pendingSeekMs automatically — don't stack another async chain.
            if (_isSeeking) return;

            _isSeeking = true;
            try
            {
                while (_pendingSeekMs >= 0)
                {
                    int targetMs = _pendingSeekMs;
                    _pendingSeekMs = -1;

                    var state = _player?.State;
                    if (state == PlayerState.Playing ||
                        state == PlayerState.Paused ||
                        state == PlayerState.Ready)
                    {
                        await _player.SetPlayPositionAsync(targetMs, false);
                        _eventSink?.Success(new Dictionary<string, object>
                        {
                            ["event"] = "position",
                            ["positionMs"] = targetMs,
                        });
                    }
                }
            }
            catch (Exception e) { Log($"Seek failed: {e.Message}", isError: true); }
            finally { _isSeeking = false; }
        }

        private void SetVolume(double volume)
        {
            try
            {
                if (_player != null)
                    _player.Volume = (float)Math.Max(0.0, Math.Min(1.0, volume / 100.0));
            }
            catch { }
        }

        private void SetRate(double rate)
        {
            try { _player?.SetPlaybackRate((float)rate); }
            catch { }
        }

        // Display modes cycling: 0=FullScreen(stretch), 1=LetterBox(original ratio), 2=CroppedFull(crop to fill)
        private static readonly PlayerDisplayMode[] DisplayModes =
        {
            PlayerDisplayMode.FullScreen,
            PlayerDisplayMode.LetterBox,
            PlayerDisplayMode.CroppedFull,
        };

        private void SetDisplayMode(int mode)
        {
            if (_player == null) return;
            try
            {
                var m = DisplayModes[mode % DisplayModes.Length];
                _currentDisplayMode = m;
                _player.DisplaySettings.Mode = m;
            }
            catch { }
        }

        private void SetVideoRect(System.Collections.IDictionary args)
        {
            if (_player == null || _videoWindow == null || args == null) return;
            try
            {
                double dpr = Convert.ToDouble(args["devicePixelRatio"]);
                int left = (int)(Convert.ToInt32(args["left"]) / dpr);
                int top = (int)(Convert.ToInt32(args["top"]) / dpr);
                int right = (int)(Convert.ToInt32(args["right"]) / dpr);
                int bottom = (int)(Convert.ToInt32(args["bottom"]) / dpr);

                // OriginalOrFull is required by the Tizen API to enable SetRoi.
                // Re-apply _currentDisplayMode afterward so a user-set mode is not lost.
                _player.DisplaySettings.Mode = PlayerDisplayMode.OriginalOrFull;
                _player.DisplaySettings.SetRoi(
                    new Tizen.Multimedia.Rectangle(left, top, right - left, bottom - top));
                if (_currentDisplayMode != PlayerDisplayMode.OriginalOrFull)
                    _player.DisplaySettings.Mode = _currentDisplayMode;
            }
            catch (Exception e) { Log($"{e.Message}", isError: true); }
        }

        // ── Helpers ──────────────────────────────────────────────────────────

        private static IDictionary<string, object> ErrorEvent(string code, string message)
            => new Dictionary<string, object>
            {
                ["event"] = "error",
                ["code"] = code,
                ["message"] = message,
            };


        /// Posts <paramref name="action"/> to the platform main thread via the
        /// SynchronizationContext captured in Setup(). Native player callbacks and
        /// the System.Timers.Timer tick run on thread-pool threads; Flutter channel
        /// calls must be on the platform thread.
        private void Post(Action action)
            => _mainContext.Post(_ => action(), null);

        private void OnVideoWindowKeyDown(object sender, EvasKeyEventArgs e)
        {
            var keyName = e.KeyName;
            Log($"Video window KeyDown: '{keyName}'");
            if (keyName != "XF86Back" && keyName != "Back") return;
            Post(() => _eventSink?.Success(new Dictionary<string, object>
            {
                ["event"] = "nativeKey",
                ["keyName"] = keyName,
            }));
        }

        private void SetEmptyInputRegion()
        {
            try
            {
                var evas = WlInput.evas_object_evas_get(_videoWindow.Handle);
                var ecoreEv = WlInput.ecore_evas_ecore_evas_get(evas);
                var wlWin = WlInput.ecore_evas_wayland2_window_get(ecoreEv);
                WlInput.ecore_wl2_window_input_region_set(wlWin, 0, 0, 0, 0);
                Log("Video window input region cleared — keyboard falls through to Flutter");
            }
            catch (Exception e)
            {
                Log($"SetEmptyInputRegion failed: {e.Message}", isError: true);
            }
        }

        private static void Log(string message, bool isError = false)
        {
            if (isError) Console.Error.WriteLine($"[TizenPlayer] {message}");
            else Console.WriteLine($"[TizenPlayer] {message}");
        }

        // ── IEventStreamHandler ──────────────────────────────────────────────

        public void OnListen(object arguments, IEventSink events)
        {
            _eventSink = events;
        }

        public void OnCancel(object arguments)
        {
            _eventSink = null;
        }

        // ── Lifecycle ────────────────────────────────────────────────────────

        private void DisposePlayer()
        {
            if (_positionTimer != null)
            {
                _positionTimer.Stop();
                _positionTimer.Elapsed -= OnPositionTick;
                _positionTimer.Dispose();
                _positionTimer = null;
            }

            if (_player != null)
            {
                try
                {
                    var state = _player.State;
                    if (state == PlayerState.Playing) _player.Stop();
                    if (state != PlayerState.Idle) _player.Unprepare();
                }
                catch { }
                _player.Dispose();
                _player = null;
            }

            if (_videoWindow != null)
            {
                _videoWindow.KeyDown -= OnVideoWindowKeyDown;
                try { _videoWindow.KeyUngrab("XF86Back"); } catch { }
                try { _videoWindow.KeyUngrab("Back"); } catch { }
                _videoWindow.Hide();
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            DisposePlayer();
            _eventSink = null;
        }
    }
}
