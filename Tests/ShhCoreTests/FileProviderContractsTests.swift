import XCTest
@testable import ShhCore

final class FileProviderContractsTests: XCTestCase {
    func testStableItemIdentifierRootAndPaths() {
        XCTAssertEqual(FileProviderItemIdentifier.root.rawValue, "NSFileProviderRootContainerItemIdentifier")
        XCTAssertTrue(FileProviderItemIdentifier.root.isRoot)
        XCTAssertEqual(FileProviderItemIdentifier.root.parentIdentifier, .root)

        let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let rootPath = RemotePath("/")
        let rootID = FileProviderItemIdentifier(hostID: hostID, remotePath: rootPath)
        XCTAssertEqual(rootID.hostID, hostID)
        XCTAssertEqual(rootID.remotePath?.description, "/")
        XCTAssertEqual(rootID.parentIdentifier, .root)

        let etcPath = RemotePath("/etc")
        let etcID = FileProviderItemIdentifier(hostID: hostID, remotePath: etcPath)
        XCTAssertEqual(etcID.hostID, hostID)
        XCTAssertEqual(etcID.remotePath?.description, "/etc")
        XCTAssertEqual(etcID.parentIdentifier, rootID)

        let sshConfigPath = RemotePath("/etc/ssh/sshd_config")
        let sshConfigID = FileProviderItemIdentifier(hostID: hostID, remotePath: sshConfigPath)
        let sshDirID = FileProviderItemIdentifier(hostID: hostID, remotePath: RemotePath("/etc/ssh"))
        XCTAssertEqual(sshConfigID.parentIdentifier, sshDirID)
    }

    func testItemContractMappingFromRemoteFile() {
        let hostID = UUID()
        let now = Date()
        let permissions = PosixPermissions(octal: 0o755)

        // Directory mapping
        let dirRemoteFile = RemoteFile(
            id: "/var/log",
            name: "log",
            path: RemotePath("/var/log"),
            entryType: .directory,
            size: 4096,
            permissions: permissions,
            modificationDate: now
        )
        let dirContract = FileProviderItemContract(remoteFile: dirRemoteFile, hostID: hostID)
        XCTAssertTrue(dirContract.isDirectory)
        XCTAssertEqual(dirContract.filename, "log")
        XCTAssertEqual(dirContract.contentTypeIdentifier, "public.folder")
        XCTAssertEqual(dirContract.size, 4096)
        XCTAssertEqual(dirContract.posixPermissions, permissions)

        // File mappings with various extensions
        let files = [
            ("script.sh", "public.shell-script"),
            ("config.json", "public.json"),
            ("notes.md", "public.plain-text"),
            ("source.swift", "public.swift-source"),
            ("image.png", "public.png"),
            ("archive.tar.gz", "org.gnu.gnu-tar-archive")
        ]

        for (filename, expectedUTI) in files {
            let file = RemoteFile(
                id: "/tmp/\(filename)",
                name: filename,
                path: RemotePath("/tmp/\(filename)"),
                entryType: .file,
                size: 1024,
                modificationDate: now
            )
            let contract = FileProviderItemContract(remoteFile: file, hostID: hostID)
            XCTAssertFalse(contract.isDirectory)
            XCTAssertEqual(contract.filename, filename)
            XCTAssertEqual(contract.contentTypeIdentifier, expectedUTI)
            XCTAssertEqual(contract.size, 1024)
        }
    }

    func testChangeAnchorSerializationAndMonotonicOrdering() {
        let anchor1 = FileProviderChangeAnchor(generation: 1)
        let anchor2 = anchor1.advanced()
        let anchor3 = anchor2.advanced()

        XCTAssertTrue(anchor1 < anchor2)
        XCTAssertTrue(anchor2 < anchor3)
        XCTAssertEqual(anchor2.generation, 2)
        XCTAssertEqual(anchor3.generation, 3)

        let encoded = anchor2.encodedData()
        let decoded = FileProviderChangeAnchor.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.generation, anchor2.generation)
    }

    func testOfflineOperationOrderingAndStatusTransitions() async {
        let cache = FileProviderMetadataCache()
        let hostID = UUID()

        let op1 = await cache.queueOfflineOperation(
            hostID: hostID,
            type: .createDirectory,
            sourcePath: RemotePath("/test/dir1")
        )
        let op2 = await cache.queueOfflineOperation(
            hostID: hostID,
            type: .uploadFile,
            sourcePath: RemotePath("/test/dir1/file.txt"),
            localTempRelativePath: "temp-123"
        )
        let op3 = await cache.queueOfflineOperation(
            hostID: hostID,
            type: .delete,
            sourcePath: RemotePath("/test/dir1/old.txt")
        )

        XCTAssertEqual(op1.sequenceNumber, 1)
        XCTAssertEqual(op2.sequenceNumber, 2)
        XCTAssertEqual(op3.sequenceNumber, 3)

        let pending = await cache.pendingOfflineOperations(hostID: hostID)
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.map(\.sequenceNumber), [1, 2, 3])

        await cache.updateOfflineOperationStatus(id: op2.id, status: .inFlight)
        let updatedPending = await cache.pendingOfflineOperations(hostID: hostID)
        XCTAssertEqual(updatedPending.count, 2)
        XCTAssertEqual(updatedPending.map(\.sequenceNumber), [1, 3])
    }

    func testBoundedCacheMetadataAndLRUEvictionRules() async {
        let hostID = UUID()
        let baseDate = Date()

        // Create 5 cached items with different access times and sizes
        var items: [FileProviderCacheMetadata] = []
        for i in 1...5 {
            let path = RemotePath("/file\(i).txt")
            let contractID = FileProviderItemIdentifier(hostID: hostID, remotePath: path)
            let contract = FileProviderItemContract(
                identifier: contractID,
                parentIdentifier: .root,
                filename: "file\(i).txt",
                isDirectory: false,
                size: 1_000_000, // 1MB
                contentTypeIdentifier: "public.plain-text"
            )
            let metadata = FileProviderCacheMetadata(
                hostID: hostID,
                remotePath: path,
                item: contract,
                cachedAt: baseDate.addingTimeInterval(Double(i * 10)),
                lastAccessDate: baseDate.addingTimeInterval(Double(i * 100)), // file1 is oldest, file5 is newest
                fileSizeBytes: 1_000_000,
                isMaterialized: true
            )
            items.append(metadata)
        }

        // Test count-based eviction: max 3 items
        let countPolicy = FileProviderEvictionPolicy(maxItemCount: 3, maxCacheSizeBytes: 100_000_000, maxAgeSeconds: 100_000)
        let evictedForCount = FileProviderEvictionRule.evaluateEviction(items: items, policy: countPolicy, now: baseDate.addingTimeInterval(1000))
        XCTAssertEqual(evictedForCount.count, 2)
        XCTAssertEqual(evictedForCount.map(\.item.filename), ["file1.txt", "file2.txt"])

        // Test size-based eviction: max 2.5 MB (should evict 3 items to get to 2 MB)
        let sizePolicy = FileProviderEvictionPolicy(maxItemCount: 100, maxCacheSizeBytes: 2_500_000, maxAgeSeconds: 100_000)
        let evictedForSize = FileProviderEvictionRule.evaluateEviction(items: items, policy: sizePolicy, now: baseDate.addingTimeInterval(1000))
        XCTAssertEqual(evictedForSize.count, 3)
        XCTAssertEqual(evictedForSize.map(\.item.filename), ["file1.txt", "file2.txt", "file3.txt"])

        // Test age-based eviction: maxAge 500 seconds
        let now = baseDate.addingTimeInterval(800)
        // file1 lastAccess is +100 (age 700), file2 is +200 (age 600), file3 is +300 (age 500), file4 is +400 (age 400), file5 is +500 (age 300)
        let agePolicy = FileProviderEvictionPolicy(maxItemCount: 100, maxCacheSizeBytes: 100_000_000, maxAgeSeconds: 550)
        let evictedForAge = FileProviderEvictionRule.evaluateEviction(items: items, policy: agePolicy, now: now)
        XCTAssertEqual(evictedForAge.count, 2)
        XCTAssertEqual(evictedForAge.map(\.item.filename), ["file1.txt", "file2.txt"])

        // Test actor integration
        let cache = FileProviderMetadataCache()
        for item in items {
            await cache.storeMetadata(item)
        }
        let evictedFromCache = await cache.evaluateAndApplyEviction(policy: countPolicy, now: baseDate.addingTimeInterval(1000))
        XCTAssertEqual(evictedFromCache.count, 2)
        let remaining = await cache.allMetadata()
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains { $0.item.filename == "file1.txt" })
    }
}
