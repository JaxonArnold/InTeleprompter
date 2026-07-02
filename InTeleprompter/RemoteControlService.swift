import Combine
import Foundation
import MultipeerConnectivity

/// The prompter's remote-control hub. One command/state protocol over
/// MultipeerConnectivity (a second iOS device running this app). The view
/// wires `onCommand` to its actions and publishes state snapshots; this
/// object owns everything about sessions and peers.
@MainActor
final class RemoteControlService: NSObject, ObservableObject {

    /// Set by the prompter view; applies commands to the UI/recording.
    var onCommand: (RemoteCommand) -> Void = { _ in }

    /// A second iOS device is connected over MultipeerConnectivity.
    @Published private(set) var peerConnected = false
    /// A nearby device asked to control this prompter; the view confirms.
    @Published private(set) var pendingPeerName: String?

    var hasRemote: Bool { peerConnected }

    private var pendingInvitation: ((Bool, MCSession?) -> Void)?

    private var mcSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    // MARK: - Lifecycle

    func start() {
        startMultipeer()
    }

    func stop() {
        // Tell remotes the prompter went away before tearing down.
        publish(.inactive)
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        mcSession?.disconnect()
        mcSession = nil
        peerConnected = false
        pendingPeerName = nil
        pendingInvitation = nil
    }

    // MARK: - State publishing

    func publish(_ state: RemoteState) {
        publishToPeers(state)
    }

    // MARK: - Pending peer confirmation

    func acceptPendingPeer() {
        pendingInvitation?(true, mcSession)
        pendingInvitation = nil
        pendingPeerName = nil
    }

    func declinePendingPeer() {
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        pendingPeerName = nil
    }

    // MARK: - MultipeerConnectivity

    private func startMultipeer() {
        let peerID = MCPeerID(displayName: UIDevice.current.name)
        let session = MCSession(peer: peerID, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        mcSession = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID, discoveryInfo: nil,
            serviceType: RemoteTransport.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    private func publishToPeers(_ state: RemoteState) {
        guard let session = mcSession, !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(state) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension RemoteControlService: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // One pending invite at a time; extras are politely refused.
            guard self.pendingPeerName == nil else {
                invitationHandler(false, nil)
                return
            }
            self.pendingPeerName = peerID.displayName
            self.pendingInvitation = invitationHandler
        }
    }
}

// MARK: - MCSessionDelegate

extension RemoteControlService: MCSessionDelegate {

    nonisolated func session(_ session: MCSession,
                             peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            self.peerConnected = !session.connectedPeers.isEmpty
        }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return }
        Task { @MainActor in self.onCommand(command) }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive stream: InputStream,
                             withName streamName: String,
                             fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession,
                             didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             with progress: Progress) {}

    nonisolated func session(_ session: MCSession,
                             didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID,
                             at localURL: URL?,
                             withError error: (any Error)?) {}
}
