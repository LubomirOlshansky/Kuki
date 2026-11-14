import Observation

/// Whether Kūki's main window can be seen. On the Mac the AppKit bundle
/// reports occlusion (a menu-bar app's scene stays `.active` while hidden or
/// covered); on iPhone it stays true and `scenePhase` does the job. Feeds
/// the `motionPaused` environment value.
@MainActor
@Observable
final class WindowVisibility {
    static let shared = WindowVisibility()
    var mainWindowVisible = true
}
