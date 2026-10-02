import AppKit
import SwiftUI
import XCTest

/// Renders a SwiftUI view in an offscreen window and reads it the way VoiceOver does: static text,
/// buttons, toggles, and fields, in reading order. Buttons can be pressed.
///
/// SwiftUI builds its accessibility tree only once an assistive app asks for it. The private
/// `AXEnhancedUserInterface` setter is how VoiceOver asks; without it the tree is empty.
@MainActor
final class Screen {
    struct Element {
        var role: String
        var label: String
        var value: String
        var enabled: Bool
        let object: NSObject

        /// What a person reads: the value for text, the label for controls.
        var text: String { value.isEmpty ? label : value }
    }

    private let window: NSWindow
    let size: CGSize

    init(_ view: some View) throws {
        try Self.enableAccessibility()
        let host = NSHostingView(rootView: AnyView(view))
        size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        // Titled, so a field can take first responder and get a field editor. Never ordered on screen.
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }

    /// Lets SwiftUI apply state changes and rebuild its tree.
    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + 0.05)
    }

    var elements: [Element] {
        var out: [Element] = []
        func walk(_ any: Any) {
            guard let o = any as? NSObject else { return }
            let role = Self.call(o, "accessibilityRole") as? String ?? ""
            if role != "AXGroup" || !(Self.call(o, "accessibilityLabel") as? String ?? "").isEmpty {
                let label = Self.call(o, "accessibilityLabel") as? String ?? ""
                out.append(Element(
                    role: role,
                    // SwiftUI names an SF Symbol button by its title ("More"), not its label.
                    label: label.isEmpty ? Self.call(o, "accessibilityTitle") as? String ?? "" : label,
                    value: Self.call(o, "accessibilityValue").map { "\($0)" } ?? "",
                    enabled: (o.value(forKey: "accessibilityEnabled") as? Bool) ?? true,
                    object: o
                ))
            }
            for child in (Self.call(o, "accessibilityChildren") as? [Any]) ?? [] { walk(child) }
        }
        if let root = window.contentView {
            for child in (Self.call(root, "accessibilityChildren") as? [Any]) ?? [] { walk(child) }
        }
        return out
    }

    /// Every piece of static text, in reading order.
    var texts: [String] {
        elements.filter { $0.role == "AXStaticText" }.map(\.value)
    }

    /// Everything a person can act on.
    var controls: [Element] {
        elements.filter {
            ["AXButton", "AXLink", "AXCheckBox", "AXTextField", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"].contains($0.role)
        }
    }

    /// The control named `label`, or nil without failing the test.
    func find(_ label: String) -> Element? {
        controls.first { $0.label == label }
    }

    func control(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        try XCTUnwrap(find(label), "no control \"\(label)\" in \(controls.map(\.label))", file: file, line: line)
    }

    func has(_ text: String) -> Bool { elements.contains { $0.text == text } }

    func press(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let element = try control(label, file: file, line: line)
        XCTAssertTrue(element.enabled, "\"\(label)\" is disabled", file: file, line: line)
        // Returns a BOOL, so the result must not be read as an object.
        _ = element.object.perform(Selector(("accessibilityPerformPress")))
        settle()
    }

    /// Replaces a text field's contents through its field editor, as typing does. Setting the
    /// accessibility value alone changes the field but never reaches SwiftUI's binding.
    func type(_ text: String, into label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let element = try control(label, file: file, line: line)
        XCTAssertTrue(element.enabled, "\"\(label)\" is disabled", file: file, line: line)
        let frame = try XCTUnwrap(element.object.value(forKey: "accessibilityFrame") as? NSRect, file: file, line: line)
        var fields: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        let field = try XCTUnwrap(fields.first {
            window.convertToScreen($0.convert($0.bounds, to: nil)).contains(NSPoint(x: frame.midX, y: frame.midY))
        }, "no NSTextField under \"\(label)\"", file: file, line: line)
        XCTAssertTrue(window.makeFirstResponder(field), file: file, line: line)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, file: file, line: line)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
    }

    private static func call(_ o: NSObject, _ name: String) -> Any? {
        let selector = Selector((name))
        guard o.responds(to: selector) else { return nil }
        return o.perform(selector)?.takeUnretainedValue()
    }

    private static func enableAccessibility() throws {
        let app = NSApplication.shared
        let setter = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
        guard app.responds(to: setter) else {
            throw XCTSkip("This macOS has no AXEnhancedUserInterface setter, so SwiftUI's tree stays empty")
        }
        app.perform(setter, with: NSNumber(value: true))
    }
}
