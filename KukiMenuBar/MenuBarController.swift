import AppKit

/// Must match `KukiStatusBar` in the app target (Kuki/Bridge/MenuBarBridge.swift)
/// exactly — the Objective-C runtime pairs them by name.
@objc(KukiStatusBar) public protocol KukiStatusBar: NSObjectProtocol {
    init()
    /// Must match the app. symbols/values/labels: parallel arrays, one per shown metric;
    /// labels are the spoken form ("CO₂ 812 parts per million") for VoiceOver.
    /// alert: 0 nothing to do · 2 stale air (◐) · 3 poor air (●).
    func update(symbols: [String], values: [String], labels: [String], alert: Int, header: String,
                details: [String], placeNames: [String], placeIDs: [String], currentPlaceID: String)
    func setVisible(_ visible: Bool)
    func setActionHandler(_ handler: @escaping (String) -> Void)
    /// Station Mode on the Mac: take the main window into (or out of) the
    /// system's full screen.
    func setFullScreen(_ on: Bool)
}

/// The AppKit half of Kūki. A Mac Catalyst app can't create a menu bar item
/// itself, so the app loads this tiny macOS bundle at launch and drives it.
@objc(KukiMenuBarController)
public final class MenuBarController: NSObject, KukiStatusBar, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var handler: ((String) -> Void)?

    /// What the button shows. Rendered only when it changes.
    private struct Title: Equatable {
        var symbols: [String]
        var values: [String]
        var labels: [String]
        var alert: Int
    }

    /// What the menu shows. Kept until the menu actually opens, then built
    /// in `menuNeedsUpdate(_:)` — no menu rebuilt every 15 seconds for nobody.
    private struct MenuData {
        var header = ""
        var details: [String] = []
        var placeNames: [String] = []
        var placeIDs: [String] = []
        var currentPlaceID = ""
    }

    private var title: Title?
    private var menuData = MenuData()

    public required override init() {
        super.init()
        item.button?.toolTip = "Kūki — air in this room"
        item.autosaveName = "KukiAir"
        render(Title(symbols: ["carbon.dioxide.cloud"], values: ["—"], labels: ["CO₂, no reading"], alert: 0))
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    public func setActionHandler(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    public func setVisible(_ visible: Bool) {
        if item.isVisible != visible { item.isVisible = visible }
    }

    public func update(symbols: [String], values: [String], labels: [String], alert: Int, header: String,
                       details: [String], placeNames: [String], placeIDs: [String], currentPlaceID: String) {
        render(Title(symbols: symbols, values: values, labels: labels, alert: alert))
        menuData = MenuData(header: header, details: details, placeNames: placeNames,
                            placeIDs: placeIDs, currentPlaceID: currentPlaceID)
    }

    // MARK: Full screen

    /// Whether *we* took the window full screen — so leaving Station Mode
    /// never pulls a window out of a full screen the person chose.
    private weak var stationWindow: NSWindow?

    public func setFullScreen(_ on: Bool) {
        // Give the window a moment to come forward and the cover to present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if on {
                guard let window = Self.mainWindow(), !window.styleMask.contains(.fullScreen) else { return }
                self.stationWindow = window
                window.toggleFullScreen(nil)
            } else if let window = self.stationWindow {
                self.stationWindow = nil
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    /// The app's main window: the key one if it can go full screen (the
    /// fixed-size Settings window can't), else any visible one that can.
    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.collectionBehavior.contains(.fullScreenPrimary) && $0.styleMask.contains(.titled)
        }
        return candidates.first { $0.isKeyWindow } ?? candidates.first { $0.isMainWindow } ?? candidates.first
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let data = menuData
        let header = NSMenuItem(title: data.header.isEmpty ? "Kūki" : data.header, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ])
        header.isEnabled = false
        menu.addItem(header)
        for line in data.details {
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let moveItem = NSMenuItem(title: "Move Sensor To", action: nil, keyEquivalent: "")
        let places = NSMenu()
        for (name, id) in zip(data.placeNames, data.placeIDs) {
            let p = NSMenuItem(title: name, action: #selector(choose(_:)), keyEquivalent: "")
            p.target = self
            p.representedObject = "place:\(id)"
            p.state = id == data.currentPlaceID ? .on : .off
            places.addItem(p)
        }
        moveItem.submenu = places
        moveItem.isEnabled = !data.placeIDs.isEmpty
        menu.addItem(moveItem)

        menu.addItem(.separator())
        menu.addItem(action("Open Kūki", "open", key: "o"))
        menu.addItem(action("Station Mode", "station", key: ""))
        menu.addItem(action("Settings…", "settings", key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Kūki", "quit", key: "q"))
    }

    private func action(_ title: String, _ id: String, key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: key)
        m.target = self
        m.representedObject = id
        return m
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switch id {
        case "quit":
            NSApp.terminate(nil)
        case "open", "station", "settings":
            NSApp.activate()
            handler?(id)
        default:
            handler?(id)
        }
    }

    // MARK: Button

    /// Symbol + number per metric, e.g. ☁︎ 812  🌡 21.4°. Symbols are template
    /// images, so the system tints them for light/dark menu bars and the
    /// highlighted state (HIG › Menu bar extras). A small mark appears only
    /// when the air needs action, and its *shape* says how much — ◐ stale,
    /// ● poor — so it never relies on colour alone.
    private func render(_ new: Title) {
        guard new != title, let button = item.button else { return }
        title = new
        let size = NSFont.systemFontSize
        let text = NSMutableAttributedString()
        if new.alert >= 2 {
            let poor = new.alert >= 3
            let color = poor
                ? NSColor(srgbRed: 0.88, green: 0.36, blue: 0.25, alpha: 1)   // shu
                : NSColor(srgbRed: 0.84, green: 0.62, blue: 0.27, alpha: 1)   // kincha
            text.append(NSAttributedString(string: poor ? "● " : "◐ ", attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: size * 0.75),
                .baselineOffset: 1,
            ]))
        }
        for (i, (symbol, value)) in zip(new.symbols, new.values).enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "   ")) }
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.95, weight: .regular)
            let description = i < new.labels.count ? new.labels[i] : nil
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                let attachment = NSTextAttachment()
                attachment.image = image
                let h = image.size.height, w = image.size.width
                attachment.bounds = CGRect(x: 0, y: -3, width: w, height: h)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " "))
            }
            // alert -1: paused (Kūki in the background) — the last value, dimmed.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            ]
            if new.alert < 0 { attributes[.foregroundColor] = NSColor.tertiaryLabelColor }
            text.append(NSAttributedString(string: value, attributes: attributes))
        }
        button.image = nil
        button.attributedTitle = text
        button.setAccessibilityLabel(Self.accessibilityLabel(labels: new.labels, values: new.values, alert: new.alert))
        button.setAccessibilityHelp("Kūki air reading. Opens the Kūki menu.")
    }

    /// "CO₂ 812 parts per million, stale air".
    static func accessibilityLabel(labels: [String], values: [String], alert: Int) -> String {
        var parts = labels.isEmpty ? values : labels
        switch alert {
        case 2: parts.append("stale air")
        case 3: parts.append("poor air, ventilate now")
        default: break
        }
        return parts.joined(separator: ", ")
    }
}
