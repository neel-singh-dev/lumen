import AppKit
import ApplicationServices

/// One UI element from the frontmost app's accessibility tree.
/// `frame` is in global screen points, top-left origin (AX convention) —
/// which is also the pointer overlay's coordinate space, so element
/// anchoring needs no coordinate math at all.
struct AXElement {
    let id: Int
    let role: String
    let label: String
    let frame: CGRect

    /// "button", "textfield" — the AX prefix is noise for the model.
    var roleName: String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }
}

/// Reads the frontmost application's accessibility tree into a compact,
/// model-readable element list. This is the "AX for grounding, pixels for
/// seeing" half of Lumen's perception: the screenshot shows the model what
/// the screen looks like; this list tells it exactly where things ARE.
final class AXReader {
    struct Snapshot {
        let appName: String
        let elements: [AXElement]
        /// Frames of secure text fields (passwords) — redacted from the
        /// capture payload before anything leaves the machine.
        let secureFrames: [CGRect]
        private let byID: [Int: AXElement]

        init(appName: String, elements: [AXElement], secureFrames: [CGRect] = []) {
            self.appName = appName
            self.elements = elements
            self.secureFrames = secureFrames
            self.byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        }

        func element(withID id: Int) -> AXElement? {
            byID[id]
        }

        var promptText: String? {
            guard !elements.isEmpty else { return nil }
            var lines = [
                "Frontmost app: \(appName)",
                "Interactive UI elements (id role \"label\" frame x,y,w,h in screen points, origin top-left):",
            ]
            for el in elements {
                let f = el.frame
                lines.append("E\(el.id) \(el.roleName) \"\(el.label)\" (\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)))")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let maxElements = 160
    private static let maxDepth = 14
    private static let maxChildrenPerNode = 50
    private static let maxStaticTexts = 40

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXLink",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXSlider", "AXMenuButton", "AXTabButton", "AXDisclosureTriangle",
        "AXSegmentedControl", "AXColorWell", "AXIncrementor", "AXCell",
    ]

    func snapshotFrontmostApp() -> Snapshot? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }

        let appName = app.localizedName ?? "unknown app"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        guard let windows: [AXUIElement] = copy(axApp, kAXWindowsAttribute) else {
            return Snapshot(appName: appName, elements: [])
        }

        // Screen bounds in AX coordinates (primary display, top-left origin).
        let screenSize = NSScreen.main?.frame.size ?? .zero
        let bounds = CGRect(origin: .zero, size: screenSize)

        var elements: [AXElement] = []
        var secureFrames: [CGRect] = []
        var nextID = 1
        var staticTexts = 0

        for window in windows.prefix(2) {
            walk(window, depth: 0, bounds: bounds, elements: &elements,
                 secureFrames: &secureFrames, nextID: &nextID, staticTexts: &staticTexts)
            if elements.count >= Self.maxElements { break }
        }

        return Snapshot(appName: appName, elements: elements, secureFrames: secureFrames)
    }

    private func walk(
        _ element: AXUIElement, depth: Int, bounds: CGRect,
        elements: inout [AXElement], secureFrames: inout [CGRect],
        nextID: inout Int, staticTexts: inout Int
    ) {
        guard depth < Self.maxDepth, elements.count < Self.maxElements else { return }

        if let role: String = copy(element, kAXRoleAttribute),
           let frame = frame(of: element),
           frame.width >= 8, frame.height >= 8,
           frame.intersects(bounds) {
            let subrole: String? = copy(element, kAXSubroleAttribute)

            if subrole == "AXSecureTextField" {
                // Never read, label, or transmit a password field's content.
                secureFrames.append(frame)
                elements.append(AXElement(id: nextID, role: role, label: "secure field (redacted)", frame: frame))
                nextID += 1
            } else {
                let label = label(of: element)
                let isInteractive = Self.interactiveRoles.contains(role)
                let isLabeledText = role == "AXStaticText" && !label.isEmpty && staticTexts < Self.maxStaticTexts

                if isInteractive || isLabeledText {
                    if isLabeledText { staticTexts += 1 }
                    elements.append(AXElement(id: nextID, role: role, label: label, frame: frame))
                    nextID += 1
                }
            }
        }

        guard let children: [AXUIElement] = copy(element, kAXChildrenAttribute) else { return }
        for child in children.prefix(Self.maxChildrenPerNode) {
            walk(child, depth: depth + 1, bounds: bounds, elements: &elements,
                 secureFrames: &secureFrames, nextID: &nextID, staticTexts: &staticTexts)
            if elements.count >= Self.maxElements { return }
        }
    }

    // MARK: - Attribute helpers

    private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? T
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func label(of element: AXUIElement) -> String {
        let candidates = [
            kAXTitleAttribute, kAXDescriptionAttribute,
            kAXPlaceholderValueAttribute, kAXValueAttribute, kAXHelpAttribute,
        ]
        for attribute in candidates {
            if let value: String = copy(element, attribute) {
                let trimmed = value
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(48))
                }
            }
        }
        return ""
    }
}
