import CoreImage
import SwiftUI
import UIKit

extension UIImage {
    /// The middle of the image at 1:1: the lock screen shows covers as they are.
    var squared: UIImage {
        guard let image = cgImage, image.width != image.height else { return self }
        let side = min(image.width, image.height)
        let area = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: area).map { UIImage(cgImage: $0, scale: scale, orientation: imageOrientation) } ?? self
    }
}

/// Loads cover images from the server once, keeps them in memory and in the
/// caches directory (iOS may purge it; images are simply loaded again).
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    private init() { memory.countLimit = 400 }

    private static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func directory(scope: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork/\(scope)", isDirectory: true)
    }

    func cached(_ id: String, scope: String) -> UIImage? {
        memory.object(forKey: "\(scope)/\(id)" as NSString)
    }

    func image(_ id: String, model: AppModel) async -> UIImage? {
        guard Self.valid(id) else { return nil }
        let scope = model.downloadScope
        let key = "\(scope)/\(id)"
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = running[key] { return await task.value }
        let file = Self.directory(scope: scope).appendingPathComponent(id)
        let api = model.api
        let task = Task<UIImage?, Never> {
            if let image = await Self.decode(contentsOf: file) { return image }
            guard let api, let data = try? await api.artwork(id) else { return nil }
            return await Self.store(data, at: file)
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func decode(contentsOf file: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return thumbnail(data)
        }.value
    }

    private static func store(_ data: Data, at file: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = thumbnail(data) else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        }.value
    }

    /// Decode and shrink to at most 900 px so big posters don't fill memory.
    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 900 else { return image.preparingForDisplay() ?? image }
        let scale = 900 / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return image.preparingThumbnail(of: size) ?? image
    }
}

/// Cover or poster with a gradient placeholder while loading or if missing.
struct ArtworkView: View {
    let id: String?
    var symbol: String = "music.note"
    var cornerRadius: CGFloat = 8
    /// width / height, e.g. 1 for album covers, 2/3 for posters.
    var aspect: CGFloat = 1
    /// Shown on the placeholder (for posters without artwork).
    var title: String? = nil
    var showsPlaceholder = true
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if showsPlaceholder {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: id) {
                guard let id else { image = nil; return }
                if let cached = ArtworkCache.shared.cached(id, scope: model.downloadScope) { image = cached; return }
                image = nil
                image = await ArtworkCache.shared.image(id, model: model)
            }
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let seed = (title ?? symbol).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.45),
                                       Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.22)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.75))
                    if let title {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 8)
                    }
                }
            }
    }
}

/// A soft cover, calculated once and then shown as a plain picture. A live blur makes
/// the graphics chip redraw a large area, and that costs battery on every page.
struct BlurredArtwork: View {
    private static let side: CGFloat = 96
    private static let context = CIContext(options: [.cacheIntermediates: false])
    @MainActor private static let cache = NSCache<NSString, UIImage>()

    let id: String?
    /// Blur radius as a share of the picture's width.
    let softness: CGFloat
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: id) { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let id else { image = nil; return }
        let key = "\(model.downloadScope)/\(id)/\(softness)" as NSString
        if let known = Self.cache.object(forKey: key) { image = known; return }
        image = nil
        guard let cover = await ArtworkCache.shared.image(id, model: model) else { return }
        let sigma = softness * Self.side
        let soft = await Task.detached(priority: .utility) { Self.blurred(cover, sigma: sigma) }.value
        guard !Task.isCancelled, let soft else { return }
        Self.cache.setObject(soft, forKey: key)
        image = soft
    }

    nonisolated private static func blurred(_ cover: UIImage, sigma: CGFloat) -> UIImage? {
        let scale = side / max(cover.size.width, cover.size.height, 1)
        let size = CGSize(width: max(1, cover.size.width * scale), height: max(1, cover.size.height * scale))
        guard let small = cover.preparingThumbnail(of: size)?.cgImage else { return nil }
        let source = CIImage(cgImage: small)
        let result = source.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: source.extent)
        return context.createCGImage(result, from: source.extent).map { UIImage(cgImage: $0) }
    }
}

/// Blurred cover behind a detail page. `fillsPage` colours the whole screen for pages
/// that do not scroll away from the cover, such as the player; otherwise it fades out below the cover.
struct ArtworkBackdrop: View {
    let id: String?
    var fillsPage = false
    var body: some View {
        GeometryReader { geometry in
            if fillsPage {
                // Larger than the page: a blur thins out towards its edges, and those stay off screen.
                let side = max(geometry.size.width, geometry.size.height) + 240
                BlurredArtwork(id: id, softness: 0.07)
                    .frame(width: side, height: side)
                    .opacity(0.5)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    // Runs down to the bottom edge and keeps the controls readable on bright covers.
                    .overlay(LinearGradient(colors: [.clear, Color(.systemBackground).opacity(0.65)], startPoint: .top, endPoint: .bottom))
            } else {
                BlurredArtwork(id: id, softness: 0.15)
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .opacity(0.5)
                    .overlay(LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom))
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Description with "Mehr/Weniger" and an optional Wikipedia link.
struct ExpandableText: View {
    let text: String
    var url: String? = nil
    var lines = 4
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if text.count > 180 {
                    Button(expanded ? String(localized: "Weniger") : String(localized: "Mehr")) { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                        .font(.callout.weight(.semibold))
                }
                Spacer()
                if let url, let link = URL(string: url) {
                    Link(destination: link) { Label(String(localized: "Wikipedia"), systemImage: "arrow.up.right.square") }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "2003-09-22" -> "22.09.2003"
func germanDate(_ value: String?) -> String? {
    guard let value, value.count >= 10 else { return value }
    let parts = value.prefix(10).split(separator: "-")
    guard parts.count == 3 else { return value }
    return "\(parts[2]).\(parts[1]).\(parts[0])"
}
