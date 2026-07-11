import Foundation

enum MerlinCLIResolver {
    static func resolve() throws -> String {
        try resolve(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    static func resolve(
        homeDirectoryPath: String,
        isExecutable: (String) -> Bool
    ) throws -> String {
        guard homeDirectoryPath.hasPrefix("/") else {
            throw MerlinInventoryError.merlinCLIPathMustBeAbsolute
        }
        let executable = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".merlin-cli/bin/merlin-cli", isDirectory: false)
            .standardizedFileURL.path
        guard executable.hasPrefix("/"), isExecutable(executable) else {
            throw MerlinInventoryError.merlinCLINotFound
        }
        return executable
    }
}
