/// Mixin for players that stream subtitle text for Flutter overlay rendering.
/// Used by PlayerTizen, where video renders in a native overlay window.
abstract interface class SubtitleStreamSupport {
  Stream<String> get subtitleTextStream;
}
