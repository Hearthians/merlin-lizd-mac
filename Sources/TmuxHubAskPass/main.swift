import Foundation

private let environment = ProcessInfo.processInfo.environment
guard let password = environment["TMUXHUB_SSH_PASSWORD"],
    !password.isEmpty,
    !password.contains("\0"),
    !password.contains(where: \.isNewline)
else {
    exit(1)
}

FileHandle.standardOutput.write(Data((password + "\n").utf8))
