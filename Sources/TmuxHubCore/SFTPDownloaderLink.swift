import Foundation

/// Handoff to the local SFTP Downloader app using the same SSH destination and
/// resolved path as the terminal that produced the link.
public enum SFTPDownloaderLink {
    public static func url(host: String, path: String) throws -> URL {
        guard IdentifierValidator.isSSHDestination(host) else {
            throw AttachmentError.invalidPath
        }
        try AttachmentPaths.validate(path)
        // Encode only unreserved characters literally. In particular a + must
        // reach Electron's URLSearchParams as %2B rather than becoming a space.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encodedHost = host.addingPercentEncoding(withAllowedCharacters: unreserved),
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { throw AttachmentError.invalidPath }
        var components = URLComponents()
        components.scheme = "sftp-downloader"
        components.host = "open"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "host", value: encodedHost),
            URLQueryItem(name: "path", value: encodedPath),
        ]
        guard let url = components.url else { throw AttachmentError.invalidPath }
        return url
    }
}
