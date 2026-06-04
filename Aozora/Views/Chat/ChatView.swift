import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main chat view with message list and input bar.
///
/// Displays the conversation for a given session, handles user input,
/// and shows streaming status. Messages auto-scroll to the bottom
/// as new content arrives.
struct ChatView: View {
    /// The CIMS app state providing access to the chat manager.
    @Environment(CIMSAppState.self) var appState

    /// The session key for this chat.
    let sessionKey: String

    /// Current text in the input field.
    @State private var inputText = ""

    /// Images staged for sending with the next message (data + MIME type).
    @State private var pendingImages: [(Data, String)] = []

    /// Whether the input field is focused.
    @FocusState private var inputFocused: Bool

    /// The chat manager from app state.
    private var chatManager: ChatManager? {
        appState.chatManager
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .onAppear { inputFocused = true }
    }

    /// Whether the initial history load has scrolled to the bottom.
    @State private var didInitialScroll = false

    /// ID of the last message, used to detect appended (vs prepended) messages.
    @State private var lastMessageId: String?

    /// Scrollable message list with auto-scroll on new messages.
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Loading indicator at top for history pagination
                    if chatManager?.isLoadingHistory == true {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }

                    // Scroll-to-top sentinel for loading older messages
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            if didInitialScroll {
                                chatManager?.loadMoreHistory()
                            }
                        }

                    if let chatManager {
                        ForEach(chatManager.messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: chatManager?.messages.last?.id) { _, newLastId in
                guard let newLastId, let chatManager else { return }
                guard let last = chatManager.messages.last else { return }

                let tailChanged = newLastId != lastMessageId
                lastMessageId = newLastId

                if !didInitialScroll {
                    // Initial history load — delay to let LazyVStack lay out
                    didInitialScroll = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                } else if tailChanged {
                    // New message appended at end — scroll with animation
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // History prepended at top — last ID unchanged, don't scroll
            }
        }
    }

    /// Input bar with text field, image previews, and send/cancel button.
    private var inputBar: some View {
        VStack(spacing: 0) {
            // Pending image previews
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, pair in
                            ZStack(alignment: .topTrailing) {
                                if let nsImage = NSImage(data: pair.0) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(.black.opacity(0.5)))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .frame(height: 72)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        send()
                        return .handled
                    }
                    .onKeyPress(.init("v"), phases: .down) { keyPress in
                        guard keyPress.modifiers.contains(.command) else { return .ignored }
                        if handlePaste() {
                            return .handled
                        }
                        return .ignored
                    }

                if chatManager?.isStreaming == true {
                    Button {
                        chatManager?.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel streaming")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Cmd+Return)")
                }
            }
            .padding()
        }
        .onDrop(of: [.image, .png, .jpeg, .tiff, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    /// Whether the send button should be enabled.
    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !pendingImages.isEmpty
        return (hasText || hasImages) && chatManager?.isStreaming != true
    }

    /// Send the current input text and any pending images via the chat manager.
    private func send() {
        guard canSend else { return }
        chatManager?.send(text: inputText, images: pendingImages)
        inputText = ""
        pendingImages = []
    }

    // MARK: - Image Paste & Drop

    /// Attempt to read image data from the system pasteboard.
    ///
    /// - Returns: `true` if an image was found and added to `pendingImages`.
    @discardableResult
    private func handlePaste() -> Bool {
        let pasteboard = NSPasteboard.general

        guard let imageType = pasteboard.availableType(
            from: [.png, .tiff, .fileURL],
        ) else { return false }

        if imageType == .fileURL,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            var found = false
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let (converted, mediaType) = convertToSupportedFormat(
                    data: data, mediaType: mediaTypeForURL(url),
                )
                pendingImages.append((converted, mediaType))
                found = true
            }
            return found
        } else if let data = pasteboard.data(forType: .png) {
            pendingImages.append((data, "image/png"))
            return true
        } else if let data = pasteboard.data(forType: .tiff) {
            if let bitmap = NSBitmapImageRep(data: data),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                pendingImages.append((pngData, "image/png"))
                return true
            }
        }

        return false
    }

    /// Handle items dropped onto the input area.
    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let (converted, mediaType) = convertToSupportedFormat(
                        data: data, mediaType: "image/png",
                    )
                    Task { @MainActor in
                        pendingImages.append((converted, mediaType))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                          let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    guard let data = try? Data(contentsOf: url) else { return }
                    let (converted, mediaType) = convertToSupportedFormat(
                        data: data, mediaType: mediaTypeForURL(url),
                    )
                    Task { @MainActor in
                        pendingImages.append((converted, mediaType))
                    }
                }
            }
        }
    }

    /// Infer MIME type from a file URL's extension.
    private func mediaTypeForURL(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "avif": "image/avif"
        case "tiff", "tif": "image/tiff"
        default: "image/png"
        }
    }

    /// Convert unsupported image formats (HEIC, AVIF, TIFF, etc.) to JPEG.
    ///
    /// The Anthropic API accepts JPEG, PNG, GIF, and WebP. Other formats
    /// are re-encoded as JPEG via `NSBitmapImageRep`.
    private func convertToSupportedFormat(data: Data, mediaType: String) -> (Data, String) {
        let supported = ["image/jpeg", "image/png", "image/gif", "image/webp"]
        if supported.contains(mediaType) { return (data, mediaType) }

        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg, properties: [.compressionFactor: 0.85],
              )
        else {
            return (data, mediaType)
        }
        return (jpegData, "image/jpeg")
    }
}
