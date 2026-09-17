import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Limits applied before an image is staged for transfer. Keeping this policy in
/// the core target makes every source (pasteboard, Photos, and Files) identical.
public struct SendImageLimits: Sendable, Hashable {
    public var maximumBytes: Int
    public var maximumPixels: Int

    public init(maximumBytes: Int = 20 * 1024 * 1024, maximumPixels: Int = 40_000_000) {
        self.maximumBytes = maximumBytes
        self.maximumPixels = maximumPixels
    }
}

public enum SendImageTransferState: Equatable, Sendable {
    case idle
    case preparing
    case transferring(TransferProgress)
    case completed(RemotePath)
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .preparing, .transferring: return true
        case .idle, .completed, .failed, .cancelled: return false
        }
    }
}

public enum SendImageError: Error, Equatable, Sendable, LocalizedError {
    case emptyData
    case malformedImage
    case imageTooLarge
    case imageDimensionsTooLarge
    case unsupportedImage
    case invalidDestination
    case unavailable
    case hostChanged
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyData: return "The selected image is empty."
        case .malformedImage: return "The selected file is not a readable image."
        case .imageTooLarge: return "Images must be 20 MB or smaller."
        case .imageDimensionsTooLarge: return "The image dimensions are too large."
        case .unsupportedImage: return "This image format is not supported."
        case .invalidDestination: return "The image destination is invalid."
        case .unavailable: return "Image transfer is unavailable while disconnected."
        case .hostChanged: return "The host changed before the image finished uploading."
        case .cancelled: return "Image transfer cancelled."
        }
    }
}

/// Image bytes that passed content validation. The extension is derived from
/// the decoded image type, never from a user supplied filename.
public struct ValidatedSendImage: Sendable, Equatable {
    public let data: Data
    public let fileExtension: String
    public let uniformTypeIdentifier: String

    public init(data: Data, fileExtension: String, uniformTypeIdentifier: String) {
        self.data = data
        self.fileExtension = fileExtension
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }
}

public enum SendImageValidator {
    public static let `default` = SendImageLimits()

    public static func validate(_ data: Data, limits: SendImageLimits = SendImageValidator.default) throws -> ValidatedSendImage {
        guard !data.isEmpty else { throw SendImageError.emptyData }
        guard data.count <= limits.maximumBytes else { throw SendImageError.imageTooLarge }

        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SendImageError.malformedImage
        }
        guard image.width > 0, image.height > 0 else { throw SendImageError.malformedImage }
        guard image.width <= limits.maximumPixels / max(1, image.height) else {
            throw SendImageError.imageDimensionsTooLarge
        }

        let identifier = type as String
        guard let fileExtension = extensionForImageType(identifier) else {
            throw SendImageError.unsupportedImage
        }
        return ValidatedSendImage(data: data, fileExtension: fileExtension, uniformTypeIdentifier: identifier)
        #else
        throw SendImageError.unsupportedImage
        #endif
    }

    #if canImport(ImageIO)
    private static func extensionForImageType(_ identifier: String) -> String? {
        switch identifier.lowercased() {
        case "public.jpeg", "public.jpg": return "jpg"
        case "public.png": return "png"
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        case "com.compuserve.gif": return "gif"
        case "public.tiff": return "tiff"
        case "org.webmproject.webp": return "webp"
        default: return nil
        }
    }
    #endif
}

/// Per-host destination override. An empty or nil override uses a private
/// directory under the conventional remote home for that login.
public enum SendImageDestination {
    public static func defaultDirectory(username: String) throws -> RemotePath {
        guard isSafeHomeComponent(username) else { throw SendImageError.invalidDestination }
        return RemotePath("/home/\(username)/.shh/images")
    }

    public static func configuredDirectory(_ value: String?) throws -> RemotePath? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw SendImageError.invalidDestination
        }
        let path = RemotePath(trimmed)
        guard !path.isRoot else { throw SendImageError.invalidDestination }
        return path
    }

    private static func isSafeHomeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }
}

public enum SendImageNaming {
    public static func fileName(extension fileExtension: String, id: UUID = UUID()) -> String {
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return "shh-image-\(id.uuidString.lowercased()).\(ext.isEmpty ? "bin" : ext)"
    }

    /// POSIX shell quoting for a path inserted into the interactive PTY. This
    /// returns bytes only - callers must not append a line ending.
    public static func shellQuote(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else { throw SendImageError.invalidDestination }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
