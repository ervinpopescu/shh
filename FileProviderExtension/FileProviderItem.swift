#if canImport(FileProvider)
import Foundation
import FileProvider
import UniformTypeIdentifiers
import ShhCore

public final class FileProviderItem: NSObject, NSFileProviderItem {
    public let contract: FileProviderItemContract

    public init(contract: FileProviderItemContract) {
        self.contract = contract
        super.init()
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        if contract.identifier.isRoot || contract.identifier.remotePath?.isRoot == true {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(contract.identifier.rawValue)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        if contract.parentIdentifier.isRoot || contract.parentIdentifier.remotePath?.isRoot == true {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(contract.parentIdentifier.rawValue)
    }

    public var filename: String {
        contract.filename
    }

    public var contentType: UTType {
        if contract.isDirectory {
            return .folder
        }
        return UTType(contract.contentTypeIdentifier) ?? .data
    }

    public var documentSize: NSNumber? {
        if contract.isDirectory {
            return nil
        }
        return NSNumber(value: contract.size)
    }

    public var creationDate: Date? {
        contract.creationDate
    }

    public var contentModificationDate: Date? {
        contract.contentModificationDate
    }

    public var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = []
        if contract.capabilities.contains(.allowsReading) {
            caps.insert(.allowsReading)
        }
        if contract.capabilities.contains(.allowsWriting) {
            caps.insert(.allowsWriting)
        }
        if contract.capabilities.contains(.allowsRenaming) {
            caps.insert(.allowsRenaming)
        }
        if contract.capabilities.contains(.allowsDeleting) {
            caps.insert(.allowsDeleting)
        }
        if contract.capabilities.contains(.allowsReparenting) {
            caps.insert(.allowsReparenting)
        }
        if contract.capabilities.contains(.allowsEvicting) {
            caps.insert(.allowsEvicting)
        }
        return caps
    }

    public var itemVersion: NSFileProviderItemVersion {
        let contentVersion = Data("\(contract.contentModificationDate?.timeIntervalSince1970 ?? 0):\(contract.size)".utf8)
        let metadataVersion = Data("\(contract.filename):\(contract.isDirectory)".utf8)
        return NSFileProviderItemVersion(contentVersion: contentVersion, metadataVersion: metadataVersion)
    }
}
#endif
