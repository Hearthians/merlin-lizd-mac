import Foundation
import Testing
import TmuxHubCore

@Suite("Loopback browser URLs")
struct LoopbackURLTests {
    @Test("recognizes supported explicit loopback authorities", arguments: [
        ("http://localhost:8765/mesh", "localhost", 8_765),
        ("HTTPS://LOCALHOST:443/path", "localhost", 443),
        ("http://localhost:000080/", "localhost", 80),
        ("http://127.0.0.1:6006/", "127.0.0.1", 6_006),
        ("http://0.0.0.0:3000/", "127.0.0.1", 3_000),
        ("http://[::1]:8080/", "::1", 8_080),
    ])
    func recognizes(link: String, remoteHost: String, remotePort: Int) throws {
        let endpoint = try #require(LoopbackURL(link))
        #expect(endpoint.originalLink == link)
        #expect(endpoint.remoteHost == remoteHost)
        #expect(endpoint.remotePort == remotePort)
    }

    @Test("rewrites only the authority and keeps escaped URL components exactly")
    func rewritesAuthority() throws {
        let endpoint = try #require(LoopbackURL(
            "HtTp://0.0.0.0:8765/a%2Fb/%E4%B8%AD?next=%2froot&x=%2B#part%20one"
        ))
        let rewritten = try #require(endpoint.rewrittenURL(localPort: 49_321))
        #expect(
            rewritten.absoluteString
                == "HtTp://127.0.0.1:49321/a%2Fb/%E4%B8%AD?next=%2froot&x=%2B#part%20one"
        )
    }

    @Test("keeps Unicode path and query content while Foundation encodes it")
    func rewritesUnicodeContent() throws {
        let endpoint = try #require(LoopbackURL(
            "http://localhost:8765/网格?名称=头盔"
        ))
        #expect(
            endpoint.rewrittenURL(localPort: 49_321)?.absoluteString
                == "http://localhost:49321/%E7%BD%91%E6%A0%BC?%E5%90%8D%E7%A7%B0=%E5%A4%B4%E7%9B%94"
        )
    }

    @Test("keeps plus signs, token punctuation, and a trailing slash")
    func rewritesTokenURL() throws {
        let endpoint = try #require(LoopbackURL(
            "https://localhost:4443/callback/?token=a+b/c=="
        ))
        #expect(
            endpoint.rewrittenURL(localPort: 49_322)?.absoluteString
                == "https://localhost:49322/callback/?token=a+b/c=="
        )
    }

    @Test("keeps empty paths, queries, and fragments")
    func keepsSuffixVariants() throws {
        for (source, expected) in [
            ("http://localhost:80", "http://localhost:12345"),
            ("http://localhost:80?", "http://localhost:12345?"),
            ("http://localhost:80#", "http://localhost:12345#"),
            ("http://localhost:80/?x=1#y", "http://localhost:12345/?x=1#y"),
            ("http://127.0.0.1:80/", "http://127.0.0.1:12345/"),
            ("http://[::1]:80/", "http://127.0.0.1:12345/"),
        ] {
            let endpoint = try #require(LoopbackURL(source))
            #expect(endpoint.rewrittenURL(localPort: 12_345)?.absoluteString == expected)
        }
    }

    @Test("rejects URLs without an allowed explicit authority", arguments: [
        "http://localhost/",
        "https://127.0.0.1/",
        "http://example.com:8765/",
        "http://localhost.example:8765/",
        "http://127.0.0.2:8765/",
        "http://127.1:8765/",
        "http://[0:0:0:0:0:0:0:1]:8765/",
        "ftp://localhost:21/",
        "file://localhost:8765/path",
    ])
    func rejectsUnsupportedAuthorities(link: String) {
        #expect(LoopbackURL(link) == nil)
    }

    @Test("rejects userinfo and ambiguous authorities", arguments: [
        "http://user@localhost:8765/",
        "http://user:pass@localhost:8765/",
        "http://localhost:8765@evil.example/",
        "http://localhost%40evil.example:8765/",
        "http://localhost:8765:90/",
        "http://[::1]extra:8765/",
        "http://::1:8765/",
        "http:////localhost:8765/",
        "http:\\localhost:8765/",
    ])
    func rejectsAmbiguousAuthorities(link: String) {
        #expect(LoopbackURL(link) == nil)
    }

    @Test("rejects invalid ports", arguments: [
        "http://localhost:/",
        "http://localhost:0/",
        "http://localhost:65536/",
        "http://localhost:-1/",
        "http://localhost:+80/",
        "http://localhost:８０/",
        "http://localhost:123456/",
    ])
    func rejectsInvalidPorts(link: String) {
        #expect(LoopbackURL(link) == nil)
    }

    @Test("rejects unsafe or malformed text")
    func rejectsUnsafeText() {
        let inputs = [
            "http://localhost:80/a b",
            "http://localhost:80/a\\b",
            "http://localhost:80/%",
            "http://localhost:80/%0",
            "http://localhost:80/%GG",
            "http://localhost:80/line\nnext",
            " http://localhost:80/",
        ]
        for input in inputs {
            #expect(LoopbackURL(input) == nil)
        }
        #expect(LoopbackURL("http://localhost:80/" + String(repeating: "a", count: 16_384)) == nil)
    }

    @Test("rejects invalid replacement ports", arguments: [0, -1, 65_536])
    func rejectsInvalidReplacementPort(port: Int) throws {
        let endpoint = try #require(LoopbackURL("http://localhost:80/"))
        #expect(endpoint.rewrittenURL(localPort: port) == nil)
    }
}
