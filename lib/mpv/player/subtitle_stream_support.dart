/// Implemented by players that expose a subtitle text stream for rendering
/// subtitles as a Flutter widget overlay instead of via native rendering.
///
/// Used by PlayerTizen: video renders in a hardware overlay window, so
/// subtitles must be composited by Flutter on top of the transparent hole.
abstract interface class SubtitleStreamSupport {
  Stream<String> get subtitleTextStream;
}
