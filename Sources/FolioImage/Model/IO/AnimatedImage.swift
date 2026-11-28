public import CoreGraphics
import FolioKit
public import Foundation
import ImageIO
public import UniformTypeIdentifiers

/// Every frame of an animated GIF, APNG, animated WebP or HEICS, with its delay, for
/// editing and saving. Writes GIF, APNG and HEICS (macOS can not write WebP).
///
/// shortcut: frames are decoded all at once; decode lazily if long animations run out of memory.
public nonisolated struct AnimatedImage {
    public struct Frame {
        public var image: CGImage
        /// Seconds.
        public var delay: Double
    }

    public var frames: [Frame]
    /// 0 = forever.
    public var loopCount = 0

    /// The ImageIO dictionary and keys that hold delays and loop counts for one format.
    /// `@unchecked`: only immutable ImageIO key constants.
    struct Keys: @unchecked Sendable {
        var dictionary: CFString
        public var delay: CFString
        var unclampedDelay: CFString
        var loopCount: CFString
    }

    static let gif = Keys(
        dictionary: kCGImagePropertyGIFDictionary, delay: kCGImagePropertyGIFDelayTime,
        unclampedDelay: kCGImagePropertyGIFUnclampedDelayTime, loopCount: kCGImagePropertyGIFLoopCount)
    static let png = Keys(
        dictionary: kCGImagePropertyPNGDictionary, delay: kCGImagePropertyAPNGDelayTime,
        unclampedDelay: kCGImagePropertyAPNGUnclampedDelayTime, loopCount: kCGImagePropertyAPNGLoopCount)
    static let heics = Keys(
        dictionary: kCGImagePropertyHEICSDictionary, delay: kCGImagePropertyHEICSDelayTime,
        unclampedDelay: kCGImagePropertyHEICSUnclampedDelayTime, loopCount: kCGImagePropertyHEICSLoopCount)
    static let webP = Keys(
        dictionary: kCGImagePropertyWebPDictionary, delay: kCGImagePropertyWebPDelayTime,
        unclampedDelay: kCGImagePropertyWebPUnclampedDelayTime, loopCount: kCGImagePropertyWebPLoopCount)

    /// The keys for writing `type`, or `nil` when Folio can not save it animated.
    static func writeKeys(for type: UTType) -> Keys? {
        if type.conforms(to: .gif) { return gif }
        if type.conforms(to: .png) { return png }
        if type.identifier == "public.heics" { return heics }
        return nil
    }

    /// Whether `type` can hold every frame (GIF, APNG, HEICS).
    public static func canAnimate(_ type: UTType) -> Bool { writeKeys(for: type) != nil }

    /// The ImageIO identifier to write `type` with: APNG is written as PNG with frames.
    private static func destinationType(for type: UTType) -> String {
        type.conforms(to: .png) ? UTType.png.identifier : type.identifier
    }
}

nonisolated extension AnimatedImage {
    public init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw FolioError("This animation couldn’t be read.")
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
        let all = [Self.gif, Self.png, Self.heics, Self.webP]
        loopCount =
            all.lazy.compactMap { keys in
                (container[keys.dictionary as String] as? [String: Any])?[keys.loopCount as String] as? Int
            }.first ?? 0
        frames = try (0..<CGImageSourceGetCount(source)).map { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw FolioError("Frame \(index + 1) of this animation couldn’t be decoded.")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let delay = all.lazy.compactMap { keys -> Double? in
                guard let dict = props[keys.dictionary as String] as? [String: Any] else { return nil }
                let unclamped = dict[keys.unclampedDelay as String] as? Double
                return (unclamped ?? 0) > 0 ? unclamped : dict[keys.delay as String] as? Double
            }.first
            return Frame(image: image, delay: delay ?? 0.1)
        }
    }

    /// Every frame with its delay, as `type` (GIF, APNG or HEICS).
    public func encoded(as type: UTType) throws -> Data {
        guard let keys = Self.writeKeys(for: type), ImageCodec.canWrite(type) || type.conforms(to: .png) else {
            throw FolioError("Folio can’t save animations as \(type.preferredFilenameExtension?.uppercased() ?? "this format").")
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, Self.destinationType(for: type) as CFString, frames.count, nil)
        else { throw FolioError("Couldn’t create the animation file.") }
        CGImageDestinationSetProperties(destination, [keys.dictionary: [keys.loopCount: loopCount]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame.image, [keys.dictionary: [keys.delay: frame.delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FolioError("Couldn’t encode the animation.") }
        return data as Data
    }

    /// Each frame as its own file of `type` (PNG by default), for “Export Frames”.
    func frameFiles(as type: UTType = .png) throws -> [Data] {
        try frames.map { try ImageCodec.encode($0.image, as: type) }
    }
}
