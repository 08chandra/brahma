import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BrahmaAppModel

/// Accepts dropped files and folders (file URLs) and links (URL or plain text) onto a composer or the library, and outlines
/// the target with a 1 px `accent` border while something hovers over it. Each dropped item is inspected on its own
/// (`ResourceDropModel.add(urls:)`); text becomes a link only if `ResourceIntake.link` accepts it.
struct ResourceDropZone: ViewModifier {
    let model: ResourceDropModel
    var enabled = true
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted && enabled {
                    RoundedRectangle(cornerRadius: BrahmaTheme.radius)
                        .strokeBorder(BrahmaTheme.accent, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                for provider in providers { Self.load(provider, into: model) }
                return true
            }
    }

    private static func load(_ provider: NSItemProvider, into model: ResourceDropModel) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if url.isFileURL { await model.add(urls: [url]) } else { model.addLink(url.absoluteString) }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? NSString else { return }
                let s = String(text)
                Task { @MainActor in model.addLink(s) }
            }
        }
    }
}

/// ⌘V with an image (and no text) on the pasteboard while the composer's field has focus: the image is added as a PNG drop
/// (`ResourceDropModel.addPasteboardImage`). Any other ⌘V is left to the field.
struct PasteImageMonitor: ViewModifier {
    let active: Bool
    let onImage: @MainActor (Data) -> Void
    @State private var box = Box()

    final class Box {
        var active = false
        var monitor: Any?
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                box.active = active
                let box = self.box, onImage = self.onImage
                box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard box.active, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v", let png = Self.pastedPNG(.general) else { return event }
                    onImage(png)
                    return nil
                }
            }
            .onDisappear {
                if let monitor = box.monitor { NSEvent.removeMonitor(monitor) }
                box.monitor = nil
            }
            .onChange(of: active) { _, now in box.active = now }
    }

    /// The pasteboard's image as PNG, only when it carries no text (a text paste stays a text paste).
    static func pastedPNG(_ pb: NSPasteboard) -> Data? {
        guard pb.string(forType: .string) == nil else { return nil }
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

/// Everything a drop host needs: the drop zone, the secret sheet and the advisory alert. `onAdvisoryConfirm` runs the
/// host's send again after "Add anyway".
struct ResourceDropHost: ViewModifier {
    let model: ResourceDropModel?
    var enabled = true
    let onAdvisoryConfirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        if let model {
            content
                .modifier(ResourceDropZone(model: model, enabled: enabled))
                // Only the model closes the sheet (each button resolves it; Escape is its Cancel button). A dismissal write
                // is ignored: it may arrive after the model has already opened the next drop's sheet.
                .sheet(item: Binding(get: { model.secretSheet }, set: { _ in })) { state in
                    ResourceSecretSheet(model: model, state: state)
                }
                .alert(Text(verbatim: ResourceDropModel.advisoryText),
                       isPresented: Binding(get: { model.advisoryPrompt }, set: { model.advisoryPrompt = $0 })) {
                    Button("Add anyway") {
                        model.acknowledgeAdvisory()
                        onAdvisoryConfirm()
                    }
                    Button("Cancel", role: .cancel) {}
                }
        } else {
            content
        }
    }
}

extension View {
    /// Drops of files, folders and links onto this view go to `model` (1 px `accent` outline while targeted).
    func resourceDropZone(_ model: ResourceDropModel) -> some View { modifier(ResourceDropZone(model: model)) }

    /// The drop zone plus the secret sheet and the advisory alert; nothing when `model` is nil.
    func resourceDrops(_ model: ResourceDropModel?, enabled: Bool = true,
                       onAdvisoryConfirm: @escaping @MainActor () -> Void) -> some View {
        modifier(ResourceDropHost(model: model, enabled: enabled, onAdvisoryConfirm: onAdvisoryConfirm))
    }
}
