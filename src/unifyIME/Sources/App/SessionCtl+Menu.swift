import AppKit
import Foundation

extension SessionCtl {
    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "行雲_繁-A Menu")
        
        let prefItem = NSMenuItem(
            title: "偏好設定…",
            action: #selector(handlePreferencesMenu(_:)),
            keyEquivalent: ","
        )
        prefItem.keyEquivalentModifierMask = [.command]
        prefItem.target = self
        if #available(macOS 11.0, *) {
            prefItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "偏好設定")
        }
        menu.addItem(prefItem)
        
        return menu
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc
    private func handlePreferencesMenu(_ sender: Any?) {
        appendRuntimeTrace("preferences.menu open")
        PreferencesWindowController.shared.show()
    }
}
