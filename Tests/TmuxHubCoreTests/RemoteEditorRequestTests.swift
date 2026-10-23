import Foundation
import Testing
import SwiftTerm
@testable import TmuxHubCore

@Test func remoteEditorRequestAcceptsEncodedPathsAndRejectsOtherClients() throws {
    let values: [String: Any] = [
        "version": 1, "requestID": UUID().uuidString, "token": "client-a",
        "path": "/home/user/a #?% 中文", "isDirectory": true,
        "hostname": "HPC4-Login-3", "serverAddress": "10.120.81.43",
    ]
    let payload = "tmuxhub-code;" + (try JSONSerialization.data(withJSONObject: values)).base64EncodedString()
    #expect(RemoteEditorRequest.decode(payload, expectedToken: "client-a")?.path == (values["path"] as? String))
    #expect(RemoteEditorRequest.decode(payload, expectedToken: "client-b") == nil)
    #expect(RemoteEditorRequest.decode(payload, expectedToken: "") == nil)
}

@Test func remoteEditorRequestRejectsInvalidProtocolAndUnsafePaths() throws {
    let base: [String: Any] = [
        "version": 1, "requestID": UUID().uuidString, "token": "client",
        "path": "/home/user/project", "isDirectory": false,
        "hostname": "server", "serverAddress": "::1",
    ]
    let invalid: [(String, Any)] = [
        ("version", 2), ("path", "relative"), ("path", "/tmp/a\ncommand"),
        ("path", "/tmp/a\u{1b}command"), ("path", "/" + String(repeating: "a", count: 8192)),
        ("requestID", "not-a-uuid"), ("hostname", "server; command"),
        ("serverAddress", "host.example.org"),
    ]
    for (key, value) in invalid {
        var fields = base
        fields[key] = value
        let payload = "tmuxhub-code;" + (try JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
        #expect(RemoteEditorRequest.decode(payload, expectedToken: "client") == nil)
    }
    #expect(RemoteEditorRequest.decode("tmuxhub-code;invalid", expectedToken: "client") == nil)
    #expect(RemoteEditorRequest.decode(String(repeating: "x", count: 24_001), expectedToken: "client") == nil)
}

@Test func remoteEditorConnectionTokenWrapsActualSSHCommand() throws {
    let token = UUID().uuidString
    let original = try TmuxCommands.remoteTerminal(destination: "host", sessionName: "work")
    let wrapped = try RemoteEditorBridge.wrap(command: original, token: token, deviceName: "Mac's Laptop")
    #expect(wrapped.executable == original.executable)
    #expect(wrapped.arguments.dropLast() == original.arguments.dropLast())
    #expect(wrapped.arguments.last?.contains(token) == true)
    #expect(wrapped.arguments.last?.hasPrefix("exec /bin/sh -c ") == true)
}


@Suite("Remote editor terminal channel")
struct RemoteEditorTerminalTests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("fragmented OSC frames dispatch only the authenticated editor request")
    func fragmentedFrames() throws {
        let token = UUID().uuidString
        let fields: [String: Any] = [
            "version": 1, "requestID": UUID().uuidString, "token": token,
            "path": "/home/user/项目 folder.with.dot", "isDirectory": true,
            "hostname": "server", "serverAddress": "127.0.0.1",
        ]
        let payload = "tmuxhub-code;" + (try JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        var requests: [RemoteEditorRequest] = []
        terminal.registerOscHandler(code: RemoteEditorBridge.oscCode) { bytes in
            if let request = RemoteEditorRequest.decode(String(decoding: bytes, as: UTF8.self), expectedToken: token) {
                requests.append(request)
            }
        }
        let frame = Array(("\u{1b}]777;" + payload + "\u{7}").utf8)
        for offset in stride(from: 0, to: frame.count, by: 7) {
            terminal.feed(byteArray: Array(frame[offset..<min(frame.count, offset + 7)]))
        }
        #expect(requests.count == 1)
        #expect(requests.first?.path == fields["path"] as? String)
        terminal.feed(text: "\u{1b}]777;tmuxhub-code;not-base64\u{7}")
        #expect(requests.count == 1)
    }
}
