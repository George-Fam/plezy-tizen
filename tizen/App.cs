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

            // EFL window for video rendering, lowered beneath Flutter's DALi window so
            // video shows through the transparent hole left by VideoRectSupport.
            Window videoWindow = null;
            try
            {
                // Hidden until a video opens to avoid stealing keyboard focus.
                videoWindow = new Window("plezy-video");
                var screenSize = Elementary.ScreenSize;
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
