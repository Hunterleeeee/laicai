import AppKit
import SwiftUI

// MARK: - ComposerTextView

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void
    var onImagePaste: ((Data, String) -> Void)?  // (pngData, mediaType)
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> ComposerWrapperView {
        let wrapper = ComposerWrapperView()

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.onSend = onSend
        textView.onImagePaste = context.coordinator.handleImagePaste
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.onFocusChange = { focused in
            context.coordinator.setFocused(focused)
        }

        wrapper.textView = textView
        wrapper.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wrapper.setContentHuggingPriority(.defaultLow, for: .vertical)
        wrapper.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrapper.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.placeholderString = placeholder
        context.coordinator.textView = textView
        context.coordinator.wrapper = wrapper
        context.coordinator.remeasure()

        return wrapper
    }

    func updateNSView(_ wrapper: ComposerWrapperView, context: Context) {
        guard let textView = wrapper.textView else { return }
        let previousPlaceholder = context.coordinator.placeholderString
        if textView.string != text {
            let recentUserEdit = Date().timeIntervalSince(context.coordinator.lastUserEditAt) < 0.25
            let looksLikeStaleEcho =
                recentUserEdit
                && !text.isEmpty
                && text.count < textView.string.count
                && textView.window?.firstResponder === textView
            if !looksLikeStaleEcho, !textView.hasMarkedText() {
                let selected = textView.selectedRanges
                textView.string = text
                if !selected.isEmpty {
                    textView.selectedRanges = selected
                }
                context.coordinator.remeasure(force: true)
                textView.needsDisplay = true
            }
        }
        textView.onSend = onSend
        textView.onImagePaste = context.coordinator.handleImagePaste
        context.coordinator.placeholderString = placeholder
        context.coordinator.onSend = onSend
        context.coordinator.onImagePaste = onImagePaste
        if previousPlaceholder != placeholder {
            textView.needsDisplay = true
        }
        // Apply focus requests from SwiftUI (e.g. right after creating a new
        // conversation). Guard against redundant first-responder churn.
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder !== textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(text: $text, isFocused: $isFocused, measuredHeight: $measuredHeight, onSend: onSend)
        coord.onImagePaste = onImagePaste
        return coord
    }

    static func dismantleNSView(_ wrapper: ComposerWrapperView, coordinator: Coordinator) {
        coordinator.textView = nil
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        let focused: Binding<Bool>
        let measuredHeight: Binding<CGFloat>
        var onSend: () -> Void
        var onImagePaste: ((Data, String) -> Void)?
        var placeholderString: String = ""
        weak var textView: ComposerNSTextView?
        weak var wrapper: ComposerWrapperView?

        init(text: Binding<String>, isFocused: Binding<Bool>, measuredHeight: Binding<CGFloat>, onSend: @escaping () -> Void) {
            self.text = text
            self.focused = isFocused
            self.measuredHeight = measuredHeight
            self.onSend = onSend
        }

        func handleImagePaste(data: Data, mediaType: String) {
            onImagePaste?(data, mediaType)
        }

        func setFocused(_ value: Bool) {
            focused.wrappedValue = value
        }

        private var lastMeasuredText: String = ""
        private var lastMeasuredWidth: CGFloat = 0
        var lastUserEditAt = Date.distantPast

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            lastUserEditAt = Date()
            text.wrappedValue = textView.string
            remeasure(force: true)
            textView.needsDisplay = true
        }

        func remeasure(force: Bool = false) {
            guard let textView = textView else { return }
            let width = max(1, wrapper?.bounds.width ?? textView.bounds.width)
            if !force,
                lastMeasuredText == textView.string,
                abs(lastMeasuredWidth - width) < 0.5
            {
                return
            }
            lastMeasuredText = textView.string
            lastMeasuredWidth = width
            guard let textContainer = textView.textContainer else { return }
            textContainer.containerSize = NSSize(
                width: max(1, width - textView.textContainerInset.width * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.layoutManager?.ensureLayout(for: textContainer)
            let used = textView.layoutManager?.usedRect(for: textContainer).height ?? 0
            let height = min(220, max(28, ceil(used + textView.textContainerInset.height * 2)))
            DispatchQueue.main.async {
                if abs(self.measuredHeight.wrappedValue - height) > 0.5 {
                    self.measuredHeight.wrappedValue = height
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard
                commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertLineBreak(_:))
            else {
                return false
            }
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            onSend()
            return true
        }
    }
}

// MARK: - ComposerWrapperView

/// 简单容器：无 intrinsic size，让 SwiftUI 完全控制尺寸。
/// layout() 时将 textView.frame 设为 bounds，确保 textView 填满整个区域。
final class ComposerWrapperView: NSView {
    var textView: ComposerNSTextView? {
        didSet {
            if let textView = textView, textView.superview == nil {
                addSubview(textView)
            }
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard let textView = textView else { return }
        textView.frame = bounds
        textView.textContainer?.containerSize = NSSize(
            width: max(0, bounds.width - textView.textContainerInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        )
        (textView.delegate as? ComposerTextView.Coordinator)?.remeasure()
    }

    override var acceptsFirstResponder: Bool { textView?.acceptsFirstResponder ?? false }

    override func becomeFirstResponder() -> Bool {
        guard let textView = textView else { return false }
        window?.makeFirstResponder(textView)
        return true
    }
}

// MARK: - ComposerNSTextView

final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onImagePaste: ((Data, String) -> Void)?

    // Catch ⌘V at the key-event level so it always routes to our paste logic
    // Only intercept when this view is the first responder to avoid stealing
    // paste from other text fields (e.g. skill search box)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "v"
        {
            pasteAsImage(sender: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Support image paste from clipboard (screenshots, copied images, file URLs)
    override func paste(_ sender: Any?) {
        pasteAsImage(sender: sender)
    }

    private func pasteAsImage(sender: Any?) {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        let hasImageType = Self.hasImageDataType(types)
        let hasFileURL = types.contains(.fileURL)
        let hasString = types.contains(.string)

        if hasString && !hasImageType && !hasFileURL {
            super.paste(sender)
            return
        }

        // Try to extract image from pasteboard
        if hasImageType, let pngData = Self.extractPNG(from: pasteboard) {
            if let callback = onImagePaste {
                callback(pngData, "image/png")
                return
            }
        }

        // Image file URL
        if hasFileURL,
            let urlData = pasteboard.data(forType: .fileURL),
            let url = URL(dataRepresentation: urlData, relativeTo: nil),
            let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
            uti.hasPrefix("public.image")
        {
            loadImageFileAsynchronously(url)
            return
        }

        // Fall back to default text paste
        super.paste(sender)
    }

    private func loadImageFileAsynchronously(_ url: URL) {
        let callback = onImagePaste
        let mediaType = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            ? "image/jpeg"
            : "image/png"
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            await MainActor.run {
                callback?(data, mediaType)
            }
        }
    }

    /// Extract PNG data from pasteboard, trying multiple strategies
    private static func extractPNG(from pasteboard: NSPasteboard) -> Data? {
        // 1) Raw PNG
        if let data = pasteboard.data(forType: .png), !data.isEmpty { return data }
        // 2) TIFF → PNG
        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty,
            let rep = NSBitmapImageRep(data: tiffData),
            let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        // 3) NSImage(pasteboard:) — catches ALL image formats (JPEG, HEIC, WebP, etc.)
        if let image = NSImage(pasteboard: pasteboard),
            let tiffData = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiffData),
            let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        return nil
    }

    private static func hasImageDataType(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let imageTypes: Set<String> = [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.jpeg",
            "public.jpg",
            "public.heic",
            "public.heif",
            "org.webmproject.webp",
        ]
        return types.contains { imageTypes.contains($0.rawValue) || $0.rawValue == "public.image" }
    }

    // Support drag-and-drop of images
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let pngData = Self.extractPNG(from: pasteboard) {
            onImagePaste?(pngData, "image/png")
            return true
        }
        // Image file URL
        if let types = pasteboard.types, types.contains(.fileURL),
            let urlData = pasteboard.data(forType: .fileURL),
            let url = URL(dataRepresentation: urlData, relativeTo: nil),
            let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
            uti.hasPrefix("public.image")
        {
            loadImageFileAsynchronously(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }

        let placeholder = (delegate as? ComposerTextView.Coordinator)?.placeholderString ?? ""
        guard !placeholder.isEmpty else { return }

        let origin = textContainerOrigin
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: 14),
        ]
        let drawRect = NSRect(
            x: origin.x,
            y: origin.y + 1,
            width: max(0, bounds.width - origin.x * 2),
            height: 18
        )
        (placeholder as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
    }
}
