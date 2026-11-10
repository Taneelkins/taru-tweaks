import AppKit

// a menu item that runs a closure (Dock menus, Model Viewer menus)
final class ClosureItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
    }
    @objc func fire() { handler() }
}
