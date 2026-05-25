using System;
using ElmSharp;
using Tizen.Flutter.Embedding;

namespace Runner
{
    public class App : FlutterApplication
    {
        private TizenMediaPlayer _tizenPlayer;

        protected override void OnCreate()
        {
            base.OnCreate();

            GeneratedPluginRegistrant.RegisterPlugins(this);

            // flutter-tizen creates its DALi window with transparent=1, so the Flutter
            // surface shows transparent pixels wherever no widget draws.
            //
            // Create a dedicated EFL window for video rendering and lower it beneath
            // Flutter's window. The player renders into it via Display(ElmSharp.Window),
            // which uses the correct EWL handle format for player_set_display(OVERLAY).
            // The VideoRectSupport path returns SizedBox.expand() (transparent), so video
            // shows through the hole in Flutter's surface.
            Window videoWindow = null;
            try
            {
                // Hidden until a video opens to avoid stealing keyboard focus.
                videoWindow = new Window("plezy-video");
                var screenSize = Elementary.GetScreenSize();
                videoWindow.Resize(screenSize.Width, screenSize.Height);
                Console.WriteLine($"[App] Video window created ({screenSize.Width}x{screenSize.Height})");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[App] Failed to create video window: {e.Message}");
            }

            _tizenPlayer = new TizenMediaPlayer(videoWindow);
            _tizenPlayer.Setup();

            new TizenWindowManager().Setup();
        }

        protected override void OnTerminate()
        {
            _tizenPlayer?.Dispose();
            base.OnTerminate();
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }
}
