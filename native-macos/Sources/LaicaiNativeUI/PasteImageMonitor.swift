import AppKit
import LaicaiNativeFoundation

// MARK: - Global Image Paste Monitor

/// Singleton that installs a single NSEvent local monitor to intercept ⌘V for image paste.
/// Using a class avoids SwiftUI @State issues with Any? and ensures the monitor persists.
final class PasteImageMonitor {
    static var monitor: Any?
    static weak var storeRef: AppStore?

    static func install(store: AppStore) {
        storeRef = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.shift),
                  !flags.contains(.control),
                  event.charactersIgnoringModifiers == "v" else { return event }

            let pb = NSPasteboard.general
            guard let pngData = extractPNG(from: pb) else { return event }

            guard let store = storeRef else { return event }
            Task { @MainActor in
                let idx = store.state.draftImages.count + 1
                let attachment = ImageAttachment(
                    data: pngData,
                    mediaType: "image/png",
                    thumbnailName: "图片 \(idx)"
                )
                store.addDraftImage(attachment)
            }
            return nil  // consume the event, don't pass to text view
        }
    }

    private static func extractPNG(from pb: NSPasteboard) -> Data? {
        // 1) Raw PNG
        if let data = pb.data(forType: .png), !data.isEmpty { return data }
        // 2) TIFF → PNG
        if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        // 3) NSImage(pasteboard:) — catches ALL formats (JPEG, HEIC, WebP, etc.)
        if let image = NSImage(pasteboard: pb),
           let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        return nil
    }
}
