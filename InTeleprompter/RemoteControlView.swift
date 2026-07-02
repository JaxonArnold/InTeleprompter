import Combine
import MultipeerConnectivity
import SwiftUI

/// Turns this device into a remote for a prompter running on another iOS
/// device: browses for nearby prompters, connects, mirrors their state, and
/// sends commands. Presented from the script list.
struct RemoteControlView: View {
    @StateObject private var model = RemoteBrowserModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.isConnected {
                    connectedContent
                } else {
                    browserContent
                }
            }
            .navigationTitle("Remote Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Browsing

    private var browserContent: some View {
        VStack(spacing: 20) {
            if model.foundPeers.isEmpty {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Looking for a prompter…")
                    .font(.headline)
                Text("Open a script's prompter on the other device and it will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            } else {
                List(model.foundPeers, id: \.displayName) { peer in
                    Button {
                        model.connect(to: peer)
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                            Text(peer.displayName)
                            Spacer()
                            if model.connectingPeerName == peer.displayName {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connected

    private var connectedContent: some View {
        VStack(spacing: 28) {
            statusHeader

            HStack(spacing: 14) {
                Button {
                    model.send(.toggleScroll)
                } label: {
                    Image(systemName: model.state.isScrolling ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)

                Button {
                    model.send(.resetScroll)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Button { model.send(.speedDown) } label: {
                    Image(systemName: "minus").frame(width: 52, height: 44)
                }
                Text("\(Int(model.state.scrollSpeed))")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .frame(maxWidth: .infinity)
                Button { model.send(.speedUp) } label: {
                    Image(systemName: "plus").frame(width: 52, height: 44)
                }
            }
            .buttonStyle(.bordered)
            .background(.quaternary, in: Capsule())

            Button {
                model.send(.toggleRecord)
            } label: {
                Label(model.state.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: model.state.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.state.isPrompterActive)

            Button("Disconnect", role: .destructive) { model.disconnect() }
                .font(.subheadline)
        }
        .padding(24)
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            if model.state.isRecording, let started = model.state.recordingStartedAt {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(started, style: .timer)
                        .font(.title.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(.red)
            } else if model.state.isPrompterActive {
                Label("Prompter ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("Waiting for prompter…", systemImage: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Browser/connection model

@MainActor
final class RemoteBrowserModel: NSObject, ObservableObject {
    @Published private(set) var foundPeers: [MCPeerID] = []
    @Published private(set) var connectingPeerName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var state = RemoteState.inactive

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?

    func start() {
        let session = MCSession(peer: peerID, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        self.session = session
        let browser = MCNearbyServiceBrowser(peer: peerID,
                                             serviceType: RemoteTransport.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
    }

    func connect(to peer: MCPeerID) {
        guard let session, let browser else { return }
        connectingPeerName = peer.displayName
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    func disconnect() {
        session?.disconnect()
        isConnected = false
        connectingPeerName = nil
        state = .inactive
    }

    func send(_ command: RemoteCommand) {
        guard let session, !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(command) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension RemoteBrowserModel: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.foundPeers.contains(peerID) {
                self.foundPeers.append(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.foundPeers.removeAll { $0 == peerID }
        }
    }
}

extension RemoteBrowserModel: MCSessionDelegate {

    nonisolated func session(_ session: MCSession,
                             peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.isConnected = true
                self.connectingPeerName = nil
            case .notConnected:
                if self.isConnected { self.disconnect() }
                self.connectingPeerName = nil
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession,
                             didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        guard let state = try? JSONDecoder().decode(RemoteState.self, from: data) else { return }
        Task { @MainActor in self.state = state }
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
