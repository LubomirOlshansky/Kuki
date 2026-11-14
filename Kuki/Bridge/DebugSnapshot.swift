#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Debug-only: render the main Mac window to a PNG, for App Store and README
/// screenshots without screen-recording permission.
///   -snapshotTo /path/shot.png   where to write (2× = Retina)
///   -windowSize 1440x900         fixed window size in points
///   -snapshotAfter 8             seconds to wait first (default 8)
///   -startTab history            now · history · export
enum DebugSnapshot {
    @MainActor
    static func runIfRequested() {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: "snapshotTo") else { return }
        let size = d.string(forKey: "windowSize")?.split(separator: "x").compactMap { Double($0) } ?? [1440, 900]
        let delay = d.object(forKey: "snapshotAfter") as? Double ?? 8
        Task { @MainActor in
            let target = CGSize(width: size.first ?? 1440, height: size.last ?? 900)
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.title != WindowID.recorderTitle {
                scene.sizeRestrictions?.minimumSize = target
                scene.sizeRestrictions?.maximumSize = target
            }
            try? await Task.sleep(for: .seconds(delay))
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .filter({ $0.title != WindowID.recorderTitle && $0.title != WindowID.settingsTitle })
                .flatMap(\.windows).first(where: { $0.bounds.width > 100 }) else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
            print("snapshot written: \(path) \(Int(window.bounds.width))x\(Int(window.bounds.height))")
            exit(0)
        }
    }
}
#endif
