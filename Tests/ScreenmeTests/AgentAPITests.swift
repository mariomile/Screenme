import XCTest
@testable import Screenme

@MainActor
final class AgentAPITests: PrefsSandboxTestCase {
    func ask(_ command: String, _ arguments: [String: Any] = [:]) async throws -> AgentChannel.Reply {
        let request = try AgentChannel.encode(AgentChannel.Request(command: command, arguments: arguments))
        // The reply goes through the wire format, as the socket sends it.
        let reply = await AgentAPI.reply(to: request)
        return try AgentChannel.decodeReply(AgentChannel.encode(reply))
    }

    func result(_ reply: AgentChannel.Reply) throws -> [String: Any] {
        guard case .result(let result) = reply else { XCTFail("expected a result, got \(reply)"); return [:] }
        return result
    }

    func error(_ reply: AgentChannel.Reply) -> String? {
        if case .error(let message) = reply { return message }
        return nil
    }

    func testEverySettingHasAUniqueKeyAndListsAsJSON() throws {
        let keys = AgentSetting.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.contains("s3Endpoint"))
        XCTAssertTrue(keys.contains("s3SecretAccessKey"))
        let listings = AgentSetting.all.map(\.listing)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: listings))
        XCTAssertTrue(listings.allSatisfy { !($0["description"] as? String ?? "").isEmpty })
        // The secret has no default to give away.
        XCTAssertNil(AgentSetting.s3SecretAccessKey.listing["default"])
    }

    func testSettingsAreCheckedAndStored() throws {
        let sounds = try XCTUnwrap(AgentSetting.named(Pref.playSounds.name))
        XCTAssertEqual(try sounds.set("off") as? Bool, false)
        XCTAssertFalse(Prefs[Pref.playSounds])
        XCTAssertEqual(try sounds.set(true) as? Bool, true)
        XCTAssertThrowsError(try sounds.set("maybe"))
        XCTAssertThrowsError(try sounds.set(2))

        let timer = try XCTUnwrap(AgentSetting.named(Pref.selfTimerSeconds.name))
        XCTAssertEqual(try timer.set("10") as? Int, 10)
        XCTAssertEqual(try timer.set(15.0) as? Int, 15)
        XCTAssertThrowsError(try timer.set(7))
        XCTAssertThrowsError(try timer.set(5.5))
        XCTAssertThrowsError(try timer.set(true), "true is not a number of seconds")

        let quality = try XCTUnwrap(AgentSetting.named(Pref.jpegQuality.name))
        XCTAssertEqual(try quality.set(0.75) as? Double, 0.75)
        XCTAssertThrowsError(try quality.set("0.2"))
        XCTAssertThrowsError(try quality.set(true))

        let format = try XCTUnwrap(AgentSetting.named(Pref.imageFormat.name))
        XCTAssertEqual(try format.set("jpg") as? String, "jpg")
        XCTAssertEqual(Prefs[Pref.imageFormat], .jpg)
        XCTAssertThrowsError(try format.set("bmp"))

        let prefix = try XCTUnwrap(AgentSetting.named(Pref.fileNamePrefix.name))
        XCTAssertEqual(try prefix.set("Shot") as? String, "Shot")
        XCTAssertThrowsError(try prefix.set(3), "a number is not text")
    }

    func testACommandWithinItsTimeAnswers() async throws {
        let result = try await AgentAPI.run(.settings, AgentArguments([:]), within: 0.5)
        XCTAssertEqual((result["settings"] as? [Any])?.count, AgentSetting.all.count)
    }

    func testTheSaveFolderMustExist() throws {
        let folder = try temporaryFolder()
        let setting = try XCTUnwrap(AgentSetting.named(Pref.saveDirectory.name))
        XCTAssertEqual(try setting.set(folder.path) as? String, folder.standardizedFileURL.path)
        XCTAssertThrowsError(try setting.set(folder.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try setting.set(""))
    }

    func testRequestsGetResultsOrErrors() async throws {
        let listed = try result(try await ask("settings"))
        let settings = try XCTUnwrap(listed["settings"] as? [[String: Any]])
        XCTAssertEqual(settings.count, AgentSetting.all.count)

        let set = try result(try await ask("set_setting", ["key": Pref.recordingFPS.name, "value": 60]))
        XCTAssertEqual(set["value"] as? Int, 60)
        XCTAssertEqual(Prefs[Pref.recordingFPS], 60)

        let wrongValue = error(try await ask("set_setting", ["key": Pref.recordingFPS.name, "value": 24]))
        XCTAssertEqual(wrongValue, "\(Pref.recordingFPS.name) takes one of 30, 60")
        let unknownKey = error(try await ask("set_setting", ["key": "nope", "value": 1]))
        XCTAssertEqual(unknownKey, "unknown setting nope; list them with the settings command")
        let noValue = error(try await ask("set_setting", ["key": Pref.recordingFPS.name]))
        XCTAssertEqual(noValue, "set_setting needs value")
        let keyOfTheWrongType = error(try await ask("set_setting", ["key": 3, "value": 1]))
        XCTAssertEqual(keyOfTheWrongType, "key must be a string")
        let unknownCommand = error(try await ask("fly"))
        XCTAssertTrue(unknownCommand?.hasPrefix("unknown command fly") == true)
        let missingFile = error(try await ask("act", ["path": "/nowhere/a.png", "action": "copy"]))
        XCTAssertEqual(missingFile, "No file at /nowhere/a.png")
        let emptyArea = error(try await ask("capture", ["mode": "area", "x": 0, "y": 0, "width": 0, "height": 5]))
        XCTAssertEqual(emptyArea, "mode area needs x, y, width and height, with a width and height above 0")

        let garbageReply = await AgentAPI.reply(to: Data("not json".utf8))
        XCTAssertEqual(AgentChannel.encode(garbageReply).last, AgentChannel.endOfMessage)
        let garbage = AgentChannel.encode(garbageReply)
        XCTAssertEqual(error(try AgentChannel.decodeReply(garbage)), "the request is not a JSON object with a command")
    }

    func testAnImageThatCannotBeRedactedIsNeverSharedAsItIs() async throws {
        let heic = try temporaryFolder().appendingPathComponent("shot.heic")
        try Data([0]).write(to: heic)
        do {
            _ = try await Redaction.redactedCopy(of: heic)
            XCTFail("a HEIC cannot be redacted")
        } catch {
            XCTAssertEqual(error as? Redaction.Failure, .unchecked)
        }
        let gif = try temporaryFolder().appendingPathComponent("a.gif")
        let none = try await Redaction.redactedCopy(of: gif)
        XCTAssertNil(none, "a GIF is shared as it is")
    }

    func testTheWireFormatRoundTrips() throws {
        let request = try AgentChannel.decodeRequest(AgentChannel.encode(AgentChannel.Request(command: "capture", arguments: ["mode": "window", "app": "Safari"])))
        XCTAssertEqual(request.command, "capture")
        XCTAssertEqual(request.arguments["app"] as? String, "Safari")
        XCTAssertNil(request.timeout)
        let line = try AgentChannel.encode(AgentChannel.Request(command: "status", arguments: ["text": "a\nb"]))
        XCTAssertEqual(line.filter { $0 == AgentChannel.endOfMessage }.count, 1, "one line, a line break in a value escaped")
        XCTAssertNil(AgentChannel.message(in: line.dropLast()), "not whole without its line break")
        let status = try AgentChannel.decodeRequest(Data(#"{"command":"status"}"#.utf8))
        XCTAssertEqual(status.arguments.count, 0)
        let timed = try AgentChannel.decodeRequest(AgentChannel.encode(AgentChannel.Request(command: "upload", arguments: [:], timeout: 1800)))
        XCTAssertEqual(timed.timeout, 1800)

        guard case .result(let result) = try AgentChannel.decodeReply(AgentChannel.encode(.result(["path": "/a.png"]))) else {
            return XCTFail("a result")
        }
        XCTAssertEqual(result["path"] as? String, "/a.png")
        XCTAssertEqual(error(try AgentChannel.decodeReply(AgentChannel.encode(.error("no")))), "no")
        XCTAssertThrowsError(try AgentChannel.decodeReply(Data("[]".utf8)))
    }

    func testArgumentsAreReadByType() throws {
        let arguments = AgentArguments(["n": 2.0, "half": 2.5, "flag": true, "text": "a", "null": NSNull()])
        XCTAssertEqual(try arguments.integer("n"), 2)
        XCTAssertThrowsError(try arguments.integer("half"))
        XCTAssertEqual(try arguments.bool("flag"), true)
        XCTAssertThrowsError(try arguments.bool("n"), "a number is not a boolean")
        XCTAssertThrowsError(try arguments.number("flag"), "a boolean is not a number")
        XCTAssertThrowsError(try arguments.string("n"))
        XCTAssertNil(try arguments.string("null"))
        XCTAssertNil(try arguments.string("missing"))
    }
}

import Network

final class AgentServerTests: PrefsSandboxTestCase {
    /// A request over a real socket, sent the way the `screenme` tool sends it.
    func testAnswersOverTheSocket() async throws {
        let socket = try temporaryFolder().appendingPathComponent("a.sock")
        XCTAssertLessThan(socket.path.utf8.count, 104)
        let server = await MainActor.run { AgentServer() }
        await server.start(at: socket)

        let request = try AgentChannel.encode(AgentChannel.Request(command: "set_setting", arguments: ["key": Pref.recordingFPS.name, "value": 60]))
        var data: Data?
        for _ in 0..<20 where data == nil {
            data = try? await exchange(request, at: socket)
            if data == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard case .result(let result) = try AgentChannel.decodeReply(try XCTUnwrap(data)) else { return XCTFail("a result") }
        XCTAssertEqual(result["value"] as? Int, 60)
        XCTAssertEqual(Prefs[Pref.recordingFPS], 60)
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "only this user may connect")
        withExtendedLifetime(server) {}
    }

    /// Every reply arrives whole: the app must not drop the connection before the tool has read it.
    func testEveryReplyArrives() async throws {
        let socket = try temporaryFolder().appendingPathComponent("b.sock")
        let server = await MainActor.run { AgentServer() }
        await server.start(at: socket)
        let request = try AgentChannel.encode(AgentChannel.Request(command: "settings", arguments: [:]))
        var failures = 0
        for attempt in 0..<100 {
            do {
                _ = try AgentChannel.decodeReply(try await exchange(request, at: socket))
            } catch {
                // The listener may still be starting on the first tries.
                if attempt > 5 { failures += 1 } else { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        XCTAssertEqual(failures, 0)
        withExtendedLifetime(server) {}
    }

    private func exchange(_ request: Data, at socket: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: .unix(path: socket.path), using: .tcp)
            let queue = DispatchQueue(label: "AgentServerTests")
            var reply = Data()
            var finished = false
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data { reply.append(data) }
                    if let message = AgentChannel.message(in: reply) {
                        finish(.success(message))
                    } else if complete {
                        finish(.failure(URLError(.networkConnectionLost)))
                    } else if let error {
                        finish(.failure(error))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .idempotent)
                    receive()
                case .waiting(let error), .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) { finish(.failure(URLError(.timedOut))) }
            connection.start(queue: queue)
        }
    }
}
