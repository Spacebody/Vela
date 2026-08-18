import Foundation
import Testing
@testable import Vela

@Suite(.serialized)
@MainActor
struct MihomoTelemetryServiceTests {
    @Test
    func decodesLegacyLogAndBuildsAuthenticatedLogsRequest() async throws {
        let connection = Sprint2TelemetryConnectionStub(messages: [
            .string(#"{"type":"warning","payload":"DNS lookup failed"}"#)
        ])
        let transport = Sprint2TelemetryTransportStub(connection: connection)
        let receivedAt = Date(timeIntervalSince1970: 1_234)
        let service = MihomoTelemetryService(
            controllerURL: try #require(URL(string: "https://127.0.0.1:9090/api/")),
            secret: "sprint-secret",
            transport: transport,
            timestampProvider: { receivedAt }
        )

        var iterator = service.logs(level: .warning).makeAsyncIterator()
        let entry = try #require(try await iterator.next())

        #expect(entry.timestamp == receivedAt)
        #expect(entry.level == .warning)
        #expect(entry.source == .controller)
        #expect(entry.message == "DNS lookup failed")

        let request = try #require(transport.recordedRequests().first)
        #expect(request.url?.scheme == "wss")
        #expect(request.url?.path == "/api/logs")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems == [URLQueryItem(name: "level", value: "warning")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sprint-secret")

        #expect(await Sprint2TelemetryTestSupport.waitUntil {
            connection.closeCount() == 1
        })
        #expect(transport.recordedRequests().count == 1)
    }

    @Test
    func decodesCompatibleStructuredLogFormat() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let connection = Sprint2TelemetryConnectionStub(messages: [
            .string(
                #"{"time":"15:04:05","level":"debug","message":"rule matched","fields":[{"key":"proxy","value":"DIRECT"}]}"#
            )
        ])
        let transport = Sprint2TelemetryTransportStub(connection: connection)
        let service = MihomoTelemetryService(
            controllerURL: try #require(URL(string: "http://127.0.0.1:9090")),
            secret: nil,
            transport: transport,
            timestampProvider: { receivedAt }
        )

        var iterator = service.logs().makeAsyncIterator()
        let entry = try #require(try await iterator.next())

        #expect(entry.level == .debug)
        #expect(entry.source == .controller)
        #expect(entry.message == "rule matched")
        #expect(entry.timestamp == receivedAt)

        let request = try #require(transport.recordedRequests().first)
        #expect(request.url?.scheme == "ws")
        #expect(request.url?.path == "/logs")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(await Sprint2TelemetryTestSupport.waitUntil {
            connection.closeCount() == 1
        })
    }

    @Test
    func controllerLogStreamRedactsPrivatePayloadBeforeYielding() async throws {
        let connection = Sprint2TelemetryConnectionStub(messages: [
            .string(
                #"{"type":"warning","payload":"[TCP] 10.0.0.9:53122 -> private.example.com:443 processPath=/Applications/Private.app Authorization: Bearer stream-secret"}"#
            )
        ])
        let transport = Sprint2TelemetryTransportStub(connection: connection)
        let service = MihomoTelemetryService(
            controllerURL: try #require(URL(string: "http://127.0.0.1:9090")),
            secret: nil,
            transport: transport
        )

        var iterator = service.logs().makeAsyncIterator()
        let entry = try #require(try await iterator.next())

        #expect(entry.message == "Mihomo log details were redacted for privacy.")
        #expect(!entry.message.contains("10.0.0.9"))
        #expect(!entry.message.contains("private.example.com"))
        #expect(!entry.message.contains("stream-secret"))
        #expect(await Sprint2TelemetryTestSupport.waitUntil {
            connection.closeCount() == 1
        })
    }

    @Test
    func decodesOfficialTrafficPayloadAndBuildsTrafficRequest() async throws {
        let connection = Sprint2TelemetryConnectionStub(messages: [
            .data(Data(#"{"up":1024,"down":2048,"upTotal":4096,"downTotal":8192}"#.utf8))
        ])
        let transport = Sprint2TelemetryTransportStub(connection: connection)
        let receivedAt = Date(timeIntervalSince1970: 9_999)
        let service = MihomoTelemetryService(
            controllerURL: try #require(URL(string: "ws://127.0.0.1:9090")),
            secret: "token",
            transport: transport,
            timestampProvider: { receivedAt }
        )

        var iterator = service.traffic().makeAsyncIterator()
        let sample = try #require(try await iterator.next())

        #expect(sample.timestamp == receivedAt)
        #expect(sample.uploadBytesPerSecond == 1_024)
        #expect(sample.downloadBytesPerSecond == 2_048)
        #expect(sample.totalUploadBytes == 4_096)
        #expect(sample.totalDownloadBytes == 8_192)

        let request = try #require(transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "ws://127.0.0.1:9090/traffic")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        #expect(await Sprint2TelemetryTestSupport.waitUntil {
            connection.closeCount() == 1
        })
    }

    @Test
    func cancellingConsumerClosesSingleUnderlyingConnection() async throws {
        let connection = Sprint2TelemetryConnectionStub(endsAfterMessages: false)
        let transport = Sprint2TelemetryTransportStub(connection: connection)
        let service = MihomoTelemetryService(
            controllerURL: try #require(URL(string: "http://127.0.0.1:9090")),
            secret: nil,
            transport: transport
        )

        let consumer = Task {
            do {
                for try await _ in service.traffic() {}
            } catch {
                // Cancellation is expected to finish the public stream cleanly.
            }
        }

        let connected = await Sprint2TelemetryTestSupport.waitUntil {
            transport.recordedRequests().count == 1
        }
        #expect(connected)

        consumer.cancel()
        await consumer.value

        #expect(await Sprint2TelemetryTestSupport.waitUntil {
            connection.closeCount() == 1
        })
        #expect(transport.recordedRequests().count == 1)
    }
}
