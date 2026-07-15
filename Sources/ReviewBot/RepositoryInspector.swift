import Foundation

enum RepositoryInspectionError: LocalizedError {
    case notGitRepository
    case missingOrigin
    case unsupportedRemote(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            "The selected folder is not a Git repository."
        case .missingOrigin:
            "The repository does not have an origin remote."
        case let .unsupportedRemote(remote):
            "The origin is not a GitHub remote: \(remote)"
        }
    }
}

enum GitHubRemoteParser {
    static func slug(from remote: String) -> String? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: value),
           let host = url.host,
           host.lowercased() == "github.com" {
            return clean(path: url.path)
        }

        guard let range = value.range(
            of: #"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        let matched = String(value[range])
        guard let separator = matched.firstIndex(where: { $0 == ":" || $0 == "/" }) else {
            return nil
        }
        return clean(path: String(matched[matched.index(after: separator)...]))
    }

    private static func clean(path: String) -> String? {
        var result = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if result.hasSuffix(".git") {
            result.removeLast(4)
        }
        return result.split(separator: "/").count == 2 ? result : nil
    }
}

struct RepositoryInspector {
    let runner: any CommandRunning

    func inspect(folder: URL) async throws -> InspectedRepository {
        let rootResult = try await runner.run(
            "git",
            arguments: ["-C", folder.path, "rev-parse", "--show-toplevel"],
            timeout: 15
        )
        guard rootResult.succeeded else { throw RepositoryInspectionError.notGitRepository }

        let path = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteResult = try await runner.run(
            "git",
            arguments: ["-C", path, "remote", "get-url", "origin"],
            timeout: 15
        )
        guard remoteResult.succeeded else { throw RepositoryInspectionError.missingOrigin }

        let remote = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = GitHubRemoteParser.slug(from: remote) else {
            throw RepositoryInspectionError.unsupportedRemote(remote)
        }

        return InspectedRepository(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            githubSlug: slug
        )
    }
}
