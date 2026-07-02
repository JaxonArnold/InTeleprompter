import Foundation
import Testing
@testable import InTeleprompter

// MARK: - Remote protocol

struct RemoteProtocolTests {

    @Test func stateCodableRoundTrip() throws {
        let state = RemoteState(
            isPrompterActive: true,
            isRecording: false,
            recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_123),
            isScrolling: true,
            scrollSpeed: 42.5
        )
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(RemoteState.self, from: data) == state)
    }

    @Test func allCommandsCodableRoundTrip() throws {
        for command in RemoteCommand.allCases {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(RemoteCommand.self, from: data) == command)
        }
    }

    @Test func serviceTypeStaysWithinBonjourLimit() {
        // Bonjour service types are capped at 15 characters; going over
        // silently breaks advertising/discovery.
        #expect(RemoteTransport.serviceType.count <= 15)
    }
}
