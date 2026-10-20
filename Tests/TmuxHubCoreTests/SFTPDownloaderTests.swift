import Foundation
import Testing
@testable import TmuxHubCore

@Suite("SFTP Downloader handoff")
struct SFTPDownloaderTests {
    @Test("handoff preserves the SSH alias and exact absolute path")
    func urlRoundTrip() throws {
        let path = "/home/user/中文 + space/#?%&= report ' \".txt"
        let url = try SFTPDownloaderLink.url(host: "user@example.test", path: path)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "sftp-downloader")
        #expect(components.host == "open")
        #expect(components.fragment == nil)
        #expect(components.queryItems == [
            URLQueryItem(name: "host", value: "user@example.test"),
            URLQueryItem(name: "path", value: path),
        ])
        #expect(!url.absoluteString.contains("+"))
        #expect(url.absoluteString.contains("%2B"))
        #expect(url.absoluteString.contains("%23"))
        #expect(url.absoluteString.contains("%3F"))
        #expect(url.absoluteString.contains("%25"))
        #expect(url.absoluteString.contains("%26"))
    }

    @Test("handoff preserves supported aliases and literal host destinations", arguments: [
        "cluster-alias", "user+tag@example.test", "[::1]", "user@[2001:db8::1]", "user@fe80::1%en0",
    ])
    func hostRoundTrip(_ host: String) throws {
        let url = try SFTPDownloaderLink.url(host: host, path: "/tmp/results")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "host" })?.value == host)
    }

    @Test("handoff rejects invalid hosts, relative paths and control characters")
    func rejectsInvalidDestinations() {
        for host in ["", "-bad", "host\nother", "host name", "host;touch /tmp/x"] {
            #expect(throws: AttachmentError.invalidPath) {
                try SFTPDownloaderLink.url(host: host, path: "/tmp/results")
            }
        }
        for path in ["", "relative/result", "~/result", "/tmp/a\n", "/tmp/a\t", "/tmp/a\u{0}"] {
            #expect(throws: AttachmentError.invalidPath) {
                try SFTPDownloaderLink.url(host: "cluster-alias", path: path)
            }
        }
    }
}
