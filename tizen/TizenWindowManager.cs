using System;
using System.Collections;
using System.Threading.Tasks;
using Tizen.Flutter.Embedding;

namespace Runner
{
    /// <summary>
    /// TV-appropriate stub for the window_manager Flutter plugin.
    ///
    /// window_manager has no Tizen implementation. Rather than scattering
    /// isTizen() guards throughout the Dart codebase, this stub registers on
    /// the same "window_manager" channel and returns sensible TV defaults so
    /// all Dart code that calls window_manager works correctly without any
    /// platform-specific branches.
    ///
    /// TV semantics:
    ///   isFullScreen / isMaximized  - true  (TV apps are always fullscreen)
    ///   isFocused / isVisible       - true
    ///   isAlwaysOnTop               - false (concept does not exist on TV)
    ///   isMinimized                 - false
    ///   All setters / listeners     - no-op (TV window state is fixed by OS)
    /// </summary>
    internal class TizenWindowManager
    {
        public void Setup()
        {
            var channel = new MethodChannel("window_manager");
            channel.SetMethodCallHandler(HandleMethodCall);
        }

        private Task<object> HandleMethodCall(MethodCall call)
        {
            object result = Respond(call.Method);
            return Task.FromResult(result);
        }

        private static object Respond(string method)
        {
            // Boolean queries — TV is always fullscreen, maximized, focused, visible.
            if (method == "isFullScreen") return true;
            if (method == "isMaximized") return true;
            if (method == "isFocused") return true;
            if (method == "isVisible") return true;
            if (method == "isMinimized") return false;
            if (method == "isAlwaysOnTop") return false;
            if (method == "isMovable") return false;
            if (method == "isResizable") return false;
            if (method == "hasShadow") return false;
            if (method == "isPreventClose") return false;

            // Numeric/string queries.
            if (method == "getOpacity") return 1.0;
            if (method == "getBrightness") return "normal";
            if (method == "getTitleBarHeight") return 0;
            if (method == "getTitle") return "Plezy";

            // Size/position — TV is fixed at 1920x1080.
            if (method == "getSize")
                return new Hashtable { { "width", 1920.0 }, { "height", 1080.0 } };
            if (method == "getPosition")
                return new Hashtable { { "x", 0.0 }, { "y", 0.0 } };

            // Everything else — setters, listeners, close, destroy — are no-ops.
            return null;
        }
    }
}
