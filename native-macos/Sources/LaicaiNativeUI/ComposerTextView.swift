import AppKit
import SwiftUI

// MARK: - ComposerTextView

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void
    var onImagePaste: ((Data, String) -> Void)?  // (pngData, mediaType)
    @Binding var isFocused: Bool

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
        textView.textColor = NSColor(red: 0.83, green: 0.82, blue: 0.78, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.43, green: 0.58, blue: 0.80, alpha: 1)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width, .height]
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

        return wrapper
    }

    func updateNSView(_ wrapper: ComposerWrapperView, context: Context) {
        guard let textView = wrapper.textView else { return }
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            if !selected.isEmpty {
                textView.selectedRanges = selected
            }
        }
        textView.onSend = onSend
        textView.onImagePaste = context.coordinator.handleImagePaste
        context.coordinator.placeholderString = placeholder
        context.coordinator.onSend = onSend
        context.coordinator.onImagePaste = onImagePaste
        textView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(text: $text, isFocused: $isFocused, onSend: onSend)
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
        var onSend: () -> Void
        var onImagePaste: ((Data, String) -> Void)?
        var placeholderString: String = ""
        weak var textView: ComposerNSTextView?

        init(text: Binding<String>, isFocused: Binding<Bool>, onSend: @escaping () -> Void) {
            self.text = text
            self.focused = isFocused
            self.onSend = onSend
        }

        func handleImagePaste(data: Data, mediaType: String) {
            onImagePaste?(data, mediaType)
        }

        func setFocused(_ value: Bool) {
            focused.wrappedValue = value
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView else { return }
            text.wrappedValue = tv.string
            tv.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertLineBreak(_:)) else {
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
            if let tv = textView, tv.superview == nil {
                addSubview(tv)
            }
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard let tv = textView else { return }
        tv.frame = bounds
        tv.textContainer?.containerSize = NSSize(
            width: max(0, bounds.width - tv.textContainerInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    override var acceptsFirstResponder: Bool { textView?.acceptsFirstResponder ?? false }

    override func becomeFirstResponder() -> Bool {
        guard let tv = textView else { return false }
        window?.makeFirstResponder(tv)
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
           event.charactersIgnoringModifiers == "v" {
            pasteAsImage(sender: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Support image paste from clipboard (screenshots, copied images, file URLs)
    override func paste(_ sender: Any?) {
        pasteAsImage(sender: sender)
    }

    private static func pasteLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let logPath = "/tmp/laicai_paste_debug.log"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    private func pasteAsImage(sender: Any?) {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let typeNames = types.map { $0.rawValue }
        Self.pasteLog("pasteboard types: \(typeNames)")
        Self.pasteLog("onImagePaste is \(onImagePaste == nil ? "nil" : "set")")

        // Try to extract image from pasteboard
        if let pngData = Self.extractPNG(from: pb) {
            NSLog("[LaicaiPaste] extracted PNG: \(pngData.count) bytes")
            if let callback = onImagePaste {
                callback(pngData, "image/png")
                return
            } else {
                NSLog("[LaicaiPaste] WARNING: onImagePaste callback is nil!")
            }
        }

        // Image file URL
        if types.contains(.fileURL),
           let urlData = pb.data(forType: .fileURL),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           uti.hasPrefix("public.image"),
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.lowercased()
            let mediaType = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
            NSLog("[LaicaiPaste] image file URL: \(url.lastPathComponent), \(data.count) bytes")
            onImagePaste?(data, mediaType)
            return
        }

        NSLog("[LaicaiPaste] falling back to text paste")
        // Fall back to default text paste
        super.paste(sender)
    }

    /// Extract PNG data from pasteboard, trying multiple strategies
    private static func extractPNG(from pb: NSPasteboard) -> Data? {
        // 1) Raw PNG
        if let data = pb.data(forType: .png), !data.isEmpty { return data }
        // 2) TIFF → PNG
        if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        // 3) NSImage(pasteboard:) — catches ALL image formats (JPEG, HEIC, WebP, etc.)
        if let image = NSImage(pasteboard: pb),
           let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        return nil
    }

    // Support drag-and-drop of images
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let pngData = Self.extractPNG(from: pb) {
            onImagePaste?(pngData, "image/png")
            return true
        }
        // Image file URL
        if let types = pb.types, types.contains(.fileURL),
           let urlData = pb.data(forType: .fileURL),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           uti.hasPrefix("public.image"),
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.lowercased()
            let mediaType = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
            onImagePaste?(data, mediaType)
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
            .foregroundColor: NSColor(red: 0.51, green: 0.48, blue: 0.46, alpha: 1),
            .font: font ?? NSFont.systemFont(ofSize: 14)
        ]
        let drawRect = NSRect(
            x: origin.x + 5,
            y: origin.y,
            width: max(0, bounds.width - origin.x * 2 - 10),
            height: 20
        )
        (placeholder as NSString).draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
    }
}
