import Foundation

/// Debug builds also append Kūki's own diagnostic lines to a plain file
/// (Application Support/Kuki/debug.log, inside the app's container), so a
/// developer can read what Apple Home did without access to the system log.
/// Release builds compile this to nothing.
enum DebugLog {
    #if DEBUG
    static let url = URL.applicationSupportDirectory.appending(path: "Kuki/debug.log")
    private static let queue = DispatchQueue(label: "com.olshanskysoft.kuki.debuglog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: .now)) [\(category)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url) // keep it small
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
    #else
    @inline(__always) static func write(_ category: String, _ message: String) {}
    #endif
}
