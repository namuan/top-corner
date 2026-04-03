import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    private var statusItemImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let fallbackConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = statusItemImage
                ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Top Corner")?
                .withSymbolConfiguration(fallbackConfig)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let viewController = GameViewController()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 820, height: 380)
        popover.behavior = .transient
        popover.contentViewController = viewController
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
