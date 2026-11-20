import Foundation

// A repository can be added by GitHub address instead of by folder. Review Bot then owns the
// clone: it checks through `gh` that the account can read the repository, makes a bare clone in
// its own data folder, and derives that clone's location and URL from the validated slug. Nothing
// a user typed, and nothing read back from `config.json`, reaches git's argv or a recursive delete.

enum CloneTransport: String, Codable, Equatable, CaseIterable {
    case https, ssh

    var label: String { self == .https ? "HTTPS" : "SSH" }
}

enum RepositoryAddressError: LocalizedError, Equatable {
    case empty
    case unrecognized
    case unsupportedHost(String)
    case notARepository

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a repository address, for example https://github.com/owner/repository or git@github.com:owner/repository.git."
        case .unrecognized:
            "That is not a repository address Review Bot understands. Use https://github.com/owner/repository or git@github.com:owner/repository.git."
        case let .unsupportedHost(host):
            "Review Bot only works with repositories on github.com, and this address points at \(host)."
        case .notARepository:
            "That address does not name a repository. It has to end in owner/repository, for example https://github.com/owner/repository."
        }
    }
}

/// A repository on github.com, rebuilt from validated `owner` and `name` components. The clone URL
/// is derived from them rather than kept from what was typed, so credentials or unexpected syntax
/// in an address never reach git.
struct GitHubRepositoryAddress: Equatable {
    let owner: String
    let name: String
    let transport: CloneTransport

    var slug: String { "\(owner)/\(name)" }

    var cloneURL: String {
        switch transport {
        case .https: "https://github.com/\(owner)/\(name).git"
        case .ssh: "git@github.com:\(owner)/\(name).git"
        }
    }

    /// Exactly `owner/name`, both components valid.
    init?(slug: String, transport: CloneTransport) {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isValidComponent(parts[0]), Self.isValidComponent(parts[1]) else {
            return nil
        }
        owner = parts[0]
        name = parts[1]
        self.transport = transport
    }

    private static let componentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && component.unicodeScalars.allSatisfy(componentCharacters.contains)
    }

    /// Accepts the shapes a developer pastes from GitHub — https, ssh, scp-like and bare
    /// `owner/repository` — and nothing that is not a repository on github.com.
    static func parse(_ input: String) throws -> GitHubRepositoryAddress {
        let value = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { throw RepositoryAddressError.empty }
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw RepositoryAddressError.unrecognized
        }

        let lowered = value.lowercased()
        let host: String
        let path: String
        let transport: CloneTransport

        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") || lowered.hasPrefix("ssh://") {
            // User, password, port, query and fragment are deliberately ignored.
            guard let components = URLComponents(string: value),
                  let componentsHost = components.host else {
                throw RepositoryAddressError.unrecognized
            }
            host = componentsHost
            path = components.path
            transport = lowered.hasPrefix("ssh://") ? .ssh : .https
        } else if value.contains("://") {
            throw RepositoryAddressError.unrecognized
        } else if let colon = value.firstIndex(of: ":") {
            // scp-like: [user@]host:path
            var scpHost = String(value[..<colon])
            if let at = scpHost.lastIndex(of: "@") {
                scpHost = String(scpHost[scpHost.index(after: at)...])
            }
            host = scpHost
            path = String(value[value.index(after: colon)...])
            transport = .ssh
        } else {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 2:
                if ["github.com", "www.github.com"].contains(parts[0].lowercased()) {
                    throw RepositoryAddressError.notARepository
                }
                host = "github.com"
                path = value
            case 3...:
                host = parts[0]
                path = parts.dropFirst().joined(separator: "/")
            default:
                throw RepositoryAddressError.unrecognized
            }
            transport = .https
        }

        var normalizedHost = host.lowercased()
        if normalizedHost.hasPrefix("www.") { normalizedHost.removeFirst(4) }
        guard !normalizedHost.isEmpty else { throw RepositoryAddressError.unrecognized }
        guard normalizedHost == "github.com" else {
            throw RepositoryAddressError.unsupportedHost(normalizedHost)
        }

        var repositoryPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repositoryPath.lowercased().hasSuffix(".git") {
            repositoryPath.removeLast(4)
        }
        repositoryPath = repositoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let address = GitHubRepositoryAddress(slug: repositoryPath, transport: transport) else {
            throw RepositoryAddressError.notARepository
        }
        return address
    }
}

// MARK: - Access check

enum RepositoryPermission: String, Equatable {
    case admin, maintain, write, triage, read
}

struct RepositoryAccess: Equatable {
    /// GitHub's canonical owner/name, in the transport that was typed.
    let address: GitHubRepositoryAddress
    let isPrivate: Bool
    let permission: RepositoryPermission
}

enum RepositoryAccessError: LocalizedError, Equatable {
    case githubCLIMissing
    case notAuthenticated
    case notFound(String)
    case forbidden(slug: String, detail: String)
    case failed(slug: String, detail: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .githubCLIMissing:
            "The GitHub CLI (gh) was not found. Install it from https://cli.github.com, run gh auth login, and try again."
        case .notAuthenticated:
            "The GitHub CLI is not signed in. Run gh auth login in a terminal, then add the repository again."
        case let .notFound(slug):
            "GitHub has no repository \(slug) that your account can see. Check the address. If the repository is private, you need to be given access to it first."
        case let .forbidden(slug, detail):
            "GitHub refused access to \(slug): \(detail)"
        case let .failed(slug, detail):
            "Could not check your access to \(slug): \(detail)"
        case let .unexpectedResponse(slug):
            "GitHub returned an unexpected response for \(slug)."
        }
    }
}

/// Asks GitHub, as the signed-in `gh` account, whether a repository exists and what that account
/// may do there. Read access is the bar: it is all GitHub requires to submit a review.
struct RepositoryAccessChecker {
    let runner: any CommandRunning

    private struct Response: Decodable {
        struct Permissions: Decodable {
            let admin: Bool?
            let maintain: Bool?
            let push: Bool?
            let triage: Bool?
            let pull: Bool?
        }

        let full_name: String?
        let `private`: Bool?
        let permissions: Permissions?
    }

    func check(_ address: GitHubRepositoryAddress) async throws -> RepositoryAccess {
        let result = try await runner.run(
            "gh",
            arguments: ["api", "repos/\(address.owner)/\(address.name)"],
            timeout: 30
        )
        guard result.succeeded else { throw Self.failure(result, slug: address.slug) }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) else {
            throw RepositoryAccessError.unexpectedResponse(address.slug)
        }

        let permission: RepositoryPermission
        if let flags = response.permissions {
            if flags.admin == true {
                permission = .admin
            } else if flags.maintain == true {
                permission = .maintain
            } else if flags.push == true {
                permission = .write
            } else if flags.triage == true {
                permission = .triage
            } else if flags.pull == true {
                permission = .read
            } else {
                throw RepositoryAccessError.forbidden(
                    slug: address.slug,
                    detail: "GitHub reports no read permission for your account."
                )
            }
        } else {
            // The 200 itself proves read access.
            permission = .read
        }

        // GitHub's own casing, and the current name if the repository was renamed.
        let canonical = response.full_name.flatMap {
            GitHubRepositoryAddress(slug: $0, transport: address.transport)
        } ?? address
        return RepositoryAccess(
            address: canonical,
            isPrivate: response.private ?? false,
            permission: permission
        )
    }

    static func failure(_ result: CommandResult, slug: String) -> RepositoryAccessError {
        let text = result.stderr + "\n" + result.stdout
        if result.exitCode == 127 { return .githubCLIMissing }
        if result.exitCode == 4 || text.contains("gh auth login") || text.contains("HTTP 401") {
            return .notAuthenticated
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? "gh exited with status \(result.exitCode)" : String(stderr.suffix(300))
        if text.contains("HTTP 404") { return .notFound(slug) }
        if text.contains("HTTP 403") { return .forbidden(slug: slug, detail: detail) }
        return .failed(slug: slug, detail: detail)
    }
}

// MARK: - Managed clone

enum ManagedCloneError: LocalizedError, Equatable {
    case invalidRepository(String)
    case cloneFailed(slug: String, transport: CloneTransport, detail: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRepository(slug):
            "\"\(slug)\" is not a valid GitHub owner/repository name, so Review Bot cannot clone it. Remove the repository and add it again."
        case let .cloneFailed(slug, .https, detail):
            "Could not clone \(slug) over HTTPS: \(detail)"
        case let .cloneFailed(slug, .ssh, detail):
            "Could not clone \(slug) over SSH: \(detail) If SSH works in your terminal but not here, add the repository by its https:// address instead. Review Bot authenticates HTTPS through gh."
        }
    }
}

/// The bare clone Review Bot keeps for a repository added by address. Every location is derived
/// from the repository's validated slug; `RepositoryConfiguration.path` is never read.
struct ManagedClone {
    /// A first clone of a large repository is the slowest thing Review Bot runs.
    static let cloneTimeout = 1_800

    let paths: StoragePaths
    let runner: any CommandRunning

    static func directory(for repository: RepositoryConfiguration, in paths: StoragePaths) -> URL? {
        guard let transport = repository.managedClone,
              let address = GitHubRepositoryAddress(slug: repository.githubSlug, transport: transport) else {
            return nil
        }
        return paths.managedCloneDirectory(for: address)
    }

    /// Filesystem only, no git process: a completed clone has both.
    static func isUsable(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let hasObjects = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("objects").path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        return hasObjects
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("HEAD").path)
    }

    /// Makes the clone if it is missing or unusable. The clone lands in a sibling `.incoming`
    /// directory and is renamed into place, so the final directory only ever exists after a
    /// completed clone — a command killed on timeout cannot leave a half-written one there.
    func ensure(_ repository: RepositoryConfiguration) async throws -> (directory: URL, cloned: Bool) {
        guard let transport = repository.managedClone,
              let address = GitHubRepositoryAddress(slug: repository.githubSlug, transport: transport) else {
            throw ManagedCloneError.invalidRepository(repository.githubSlug)
        }
        let directory = paths.managedCloneDirectory(for: address)
        if Self.isUsable(directory) { return (directory, false) }

        let incoming = directory.appendingPathExtension("incoming")
        try? FileManager.default.removeItem(at: incoming)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arguments = ["clone", "--bare", "--quiet"]
        if address.transport == .https {
            // The same identity the access check used. `git clone -c` writes these into the
            // clone's own config, so later fetches authenticate the same way. The empty value
            // first resets any helper inherited from the user's global config.
            arguments += [
                "-c", "credential.https://github.com.helper=",
                "-c", "credential.https://github.com.helper=!gh auth git-credential",
            ]
        }
        arguments += ["--", address.cloneURL, incoming.path]

        let cloneResult: CommandResult
        do {
            cloneResult = try await runner.run(
                "git",
                arguments: arguments,
                currentDirectory: nil,
                environment: ["GIT_TERMINAL_PROMPT": "0"],
                timeout: Self.cloneTimeout
            )
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw ManagedCloneError.cloneFailed(
                slug: address.slug,
                transport: address.transport,
                detail: error.localizedDescription
            )
        }
        guard cloneResult.succeeded else {
            try? FileManager.default.removeItem(at: incoming)
            let stderr = cloneResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagedCloneError.cloneFailed(
                slug: address.slug,
                transport: address.transport,
                detail: stderr.isEmpty
                    ? "git exited with status \(cloneResult.exitCode)"
                    : String(stderr.suffix(400))
            )
        }

        do {
            try FileManager.default.moveItem(at: incoming, to: directory)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw ManagedCloneError.cloneFailed(
                slug: address.slug,
                transport: address.transport,
                detail: error.localizedDescription
            )
        }
        return (directory, true)
    }

    /// Deletes the derived clone directory, never a path read from `repository.path`.
    func remove(_ repository: RepositoryConfiguration) {
        guard let directory = Self.directory(for: repository, in: paths) else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: directory.appendingPathExtension("incoming"))
        // `rmdir` only removes an empty directory. A recursive delete here could wipe a sibling
        // clone's `.incoming` that appeared since the emptiness was checked.
        rmdir(directory.deletingLastPathComponent().path)
    }
}
