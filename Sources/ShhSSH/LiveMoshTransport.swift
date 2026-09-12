import Foundation
import ShhCore

public final class LiveMoshTransport: MoshTransport, SSHTransport, @unchecked Sendable {
    public let sshTransport: any SSHTransport
    public let bootstrapper: MoshBootstrapper
    private let channelFactory: (@Sendable (String, UInt16) -> any MoshDatagramChannel)?

    public init(
        sshTransport: any SSHTransport = LiveSSHTransport(),
        bootstrapper: MoshBootstrapper = MoshBootstrapper(),
        channelFactory: (@Sendable (String, UInt16) -> any MoshDatagramChannel)? = nil
    ) {
        self.sshTransport = sshTransport
        self.bootstrapper = bootstrapper
        self.channelFactory = channelFactory
    }

    public func connect(
        host: ShhCore.Host,
        identity: IdentityDescriptor?,
        trustEvaluator: any HostTrustEvaluator,
        initialSize: TerminalSize = TerminalSize(columns: 80, rows: 24)
    ) async throws -> any SSHConnection {
        let moshOptions: MoshOptions
        switch host.connection {
        case .mosh(let opts):
            moshOptions = opts
        case .ssh(let sshOpts):
            moshOptions = MoshOptions(sshOptions: sshOpts)
        case .proxyJump(let jumpOpts):
            moshOptions = MoshOptions(sshOptions: jumpOpts.sshOptions)
        }

        // Ephemeral host configuration for SSH bootstrap exec
        let bootstrapHost = try ShhCore.Host(
            id: host.id,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            groupID: host.groupID,
            tagIDs: host.tagIDs,
            identityID: host.identityID,
            connection: .ssh(moshOptions.sshOptions),
            health: host.health
        )

        let sshConnection = try await sshTransport.connect(
            host: bootstrapHost,
            identity: identity,
            trustEvaluator: trustEvaluator,
            initialSize: initialSize
        )

        guard let commandExecutor = sshConnection as? any SSHCommandExecuting else {
            await sshConnection.close()
            throw TransportError.unsupported
        }

        let sessionInfo: MoshSessionInfo
        do {
            sessionInfo = try await bootstrapper.bootstrap(
                executor: commandExecutor,
                options: moshOptions,
                initialSize: initialSize
            )
        } catch {
            await sshConnection.close()
            throw error
        }

        // SSH bootstrap connection is torn down after obtaining UDP credentials
        await sshConnection.close()

        let channel: any MoshDatagramChannel
        if let factory = self.channelFactory {
            channel = factory(host.hostname, sessionInfo.udpPort)
        } else {
            channel = LiveMoshDatagramChannel(
                remoteHost: host.hostname,
                remotePort: sessionInfo.udpPort
            )
        }

        let connection = MoshConnection(
            sessionInfo: sessionInfo,
            options: moshOptions,
            remoteHostname: host.hostname,
            channel: channel
        )

        try await connection.start()
        return connection
    }
}
