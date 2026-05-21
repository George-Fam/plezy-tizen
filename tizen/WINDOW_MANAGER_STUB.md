# Tizen window_manager stub — implementation plan

## Problem

`window_manager` has no Tizen implementation. Every call throws
`MissingPluginException`. Currently worked around with scattered
`PlatformDetector.isTizen()` guards in Dart code.

## Better approach

Register a C# method channel handler in `App.cs` (or a new
`TizenWindowManager.cs`) on the `"window_manager"` channel that returns
TV-appropriate defaults. This makes all Dart code just work without
application-level guards.

## TV defaults

| Method | Return |
|---|---|
| `ensureInitialized`, `waitUntilReadyToShow` | `null` |
| `isFullScreen`, `isMaximized` | `true` (TV is always fullscreen) |
| `isFocused`, `isVisible` | `true` |
| `isMinimized`, `isAlwaysOnTop`, `isMovable`, `isResizable`, `hasShadow` | `false` |
| `setFullScreen`, `maximize`, `unmaximize`, `minimize`, `restore` | `null` (no-op) |
| `setAlwaysOnTop`, `focus`, `blur`, `show`, `hide` | `null` (no-op) |
| `addListener`, `removeListener`, `startListening` | `null` (no events fire on TV) |
| `getSize` | `{width: 1920.0, height: 1080.0}` |
| `getPosition` | `{x: 0.0, y: 0.0}` |
| `getTitle` | `"Plezy"` |
| `getOpacity` | `1.0` |
| `getBrightness` | `"normal"` |
| `getTitleBarHeight` | `0` |
| All other setters | `null` (no-op) |
| Unknown methods | `null` (avoid throwing) |

## After implementing

Remove these now-redundant Dart guards (all added for Tizen):

- `fullscreen_state_manager.dart` — `if (PlatformDetector.isTizen()) return;`
  in `toggleFullscreen()`, `enterFullscreen()`, `exitFullscreen()`
- `visibility.dart` — `if (PlatformDetector.isTizen()) return;`
  in `_exitFullscreenIfNeeded()`, `_initAlwaysOnTopState()`
- `visibility.dart` — `if (!Platform.isMacOS || PlatformDetector.isTizen()) return;`
  in `_updateTrafficLightVisibility()`
- `main.dart` — the `!PlatformDetector.isTizen()` guard around
  `windowManager.ensureInitialized()`

## Methods actually called in the app

Found via grep:
- `ensureInitialized`, `addListener`, `removeListener`
- `isFullScreen`, `setFullScreen`
- `isMaximized`, `maximize`, `unmaximize`
- `isFocused`
- `isAlwaysOnTop`, `setAlwaysOnTop`
