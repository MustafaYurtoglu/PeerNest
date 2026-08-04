import Foundation
import Testing
@testable import PeerNest

@MainActor
struct PeerProtocolTests {
    private let peerID = UUID()

    @Test func completeFrame() async throws {
        let message = try makeMessage("hello")
        let decoded = try await PeerFrameDecoder().append(PeerFrameCodec.encode(message))
        #expect(decoded.map(\.messageID) == [message.messageID])
    }

    @Test func fragmentedLengthPrefix() async throws {
        let message = try makeMessage("prefix")
        let frame = try PeerFrameCodec.encode(message)
        let decoder = PeerFrameDecoder()
        #expect(try await decoder.append(frame.prefix(2)).isEmpty)
        #expect(try await decoder.append(frame.dropFirst(2)).map(\.messageID) == [message.messageID])
    }

    @Test func fragmentedPayload() async throws {
        let message = try makeMessage(String(repeating: "x", count: 1_000))
        let frame = try PeerFrameCodec.encode(message)
        let decoder = PeerFrameDecoder()
        #expect(try await decoder.append(frame.prefix(30)).isEmpty)
        #expect(try await decoder.append(frame.dropFirst(30)).count == 1)
    }

    @Test func multipleFramesInOneBuffer() async throws {
        let first = try makeMessage("first")
        let second = try makeMessage("second")
        var data = try PeerFrameCodec.encode(first)
        data.append(try PeerFrameCodec.encode(second))
        #expect(try await PeerFrameDecoder().append(data).map(\.messageID) == [first.messageID, second.messageID])
    }

    @Test func oversizedFrameRejected() async {
        var length = UInt32(PeerProtocolConstants.maximumMessageSize + 1).bigEndian
        let data = withUnsafeBytes(of: &length) { Data($0) }
        await #expect(throws: PeerFrameError.oversizedFrame(PeerProtocolConstants.maximumMessageSize + 1)) {
            try await PeerFrameDecoder().append(data)
        }
    }

    @Test func malformedPayloadRejected() async {
        let payload = Data("{}".utf8)
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        await #expect(throws: PeerFrameError.malformedPayload) {
            try await PeerFrameDecoder().append(frame)
        }
    }

    @Test func launchArgumentsRejectMissingAndInvalidPorts() {
        #expect(throws: DebugLaunchConfiguration.ConfigurationError.missingValue("--peer-host")) {
            try DebugLaunchConfiguration.parse(["PeerNest", "--peer-host"])
        }
        #expect(throws: DebugLaunchConfiguration.ConfigurationError.invalidPort("--listen-port", "70000")) {
            try DebugLaunchConfiguration.parse(["PeerNest", "--listen-port", "70000"])
        }
    }

    @Test func debugTestNamespaceIsValidatedAndParsed() throws {
        #if DEBUG
        let configuration = try DebugLaunchConfiguration.parse([
            "PeerNest", "--test-namespace", "peer-a",
            "--integration-auto-start", "--integration-auto-connect"
        ])
        #expect(configuration.testNamespace == "peer-a")
        #expect(configuration.integrationAutoStart)
        #expect(configuration.integrationAutoConnect)
        #expect(throws: DebugLaunchConfiguration.ConfigurationError.invalidTestNamespace("../production")) {
            try DebugLaunchConfiguration.parse(["PeerNest", "--test-namespace", "../production"])
        }
        #endif
    }

    private func makeMessage(_ value: String) throws -> PeerMessage {
        try PeerMessage(senderPeerID: peerID, messageType: .ping, payload: value)
    }
}
