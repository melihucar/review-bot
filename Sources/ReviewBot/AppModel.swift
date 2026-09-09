import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = "Starting…"
    @Published private(set) var isRunning = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var toolAvailability: [String: Bool] = [:]
    @Published private(set) var reviewersWithSavedKey: Set<ReviewerName> = []
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var pendingReviews: [ReviewQueueItem] = []
    /// Every review running right now — a poll reviews several pull requests at once,
    /// so this is a list. It was a single optional while polls were sequential, which
    /// meant the second review to start erased the first from the menu bar even though
    /// it was still running.
    @Published private(set) var runningReviews: [ReviewQueueItem] = []
    @Published var errorMessage: String?

    let settings: SettingsStore
    let history: HistoryStore

    private let paths: StoragePaths
    private let runner: any CommandRunning
    private let credentials: any CredentialStoring
    private let engine: ReviewEngine
    private var schedulerTask: Task<Void, Never>?
    private var settingsWindowController: NSWindowController?
    private var hasStarted = false

    init(
        paths: StoragePaths = StoragePaths(),
        credentials: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.paths = paths
        self.credentials = credentials
        runner = ProcessRunner()
        settings = SettingsStore(paths: paths)
        history = HistoryStore(paths: paths)
        engine = ReviewEngine(paths: paths, runner: runner, credentials: credentials)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        schedulerTask = Task { [weak self] in
            guard let self else { return }
            await refreshToolAvailability()
            await schedulerLoop()
        }
    }

    func runNow() {
        guard !isRunning else { return }
        Task { [weak self] in
            await self?.performPoll(manual: true)
        }
    }

    func togglePaused() {
        settings.configuration.isPaused.toggle()
        status = settings.configuration.isPaused ? "Monitoring paused" : "Monitoring resumed"
        if !settings.configuration.isPaused, lastCheckDate == nil {
            runNow()
        }
    }

    func addRepository(folder: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let repository = try await RepositoryInspector(runner: runner).inspect(folder: folder)
                settings.add(repository)
                status = "Added \(repository.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshToolAvailability() async {
        var statuses: [String: Bool] = [:]
        // The probe list is derived from the reviewers rather than written out, so a reviewer
        // added to `ReviewerName` is checked without a second edit here.
        for tool in ["gh"] + ReviewerName.allCases.compactMap(\.commandName) {
            let result = try? await runner.run("which", arguments: [tool], timeout: 10)
            statuses[tool] = result?.succeeded == true
        }
        toolAvailability = statuses
        await refreshSavedKeys()
    }

    /// Which reviewers have a key available — from the Keychain, or from the environment, which
    /// takes precedence over it.
    ///
    /// Only reviewers actually configured for key auth are looked up: reading a Keychain item
    /// can prompt for access on an ad-hoc-signed build, and a developer using signed-in CLIs
    /// should never see that prompt. An environment-supplied key is answered without touching
    /// the Keychain at all, so it cannot prompt.
    ///
    /// The read happens off the main actor, which is why this is `async`. A Keychain prompt
    /// blocks the thread that raises it until the user answers, and blocking this one freezes
    /// the settings window that is asking the question.
    func refreshSavedKeys() async {
        let resolved = await ResolvedCredentials.resolve(
            ReviewerName.allCases.filter { reviewer in
                reviewer.supportsAPIKeyAuth
                    && settings.configuration.settings(for: reviewer).authMode == .apiKey
            },
            from: credentials
        )
        reviewersWithSavedKey = resolved.reviewersWithKey
    }

    /// What a Keychain write left in effect, read back on the same detached task that performed
    /// the write so the panel and the status line can never disagree about it.
    private struct CredentialWriteOutcome: Sendable {
        var effective: String?
        var failure: String?
    }

    func saveAPIKey(_ key: String, for reviewer: ReviewerName) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.setAPIKey(trimmed, for: reviewer)
        }
        if let failure = outcome.failure {
            errorMessage = "Could not save the \(reviewer.rawValue) API key: \(failure)"
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        if outcome.effective == nil {
            // The write succeeded but reading it back did not, which on an ad-hoc-signed build
            // means the Keychain prompt was denied. Reporting a plain "Saved" here would leave
            // the panel below saying no key is saved, and the next review failing for a reason
            // nothing on screen explained.
            status = """
            Saved the \(reviewer.rawValue) API key, but it could not be read back — allow \
            Review Bot access when macOS asks, or \(reviewer.rawValue) reviews will fail
            """
        } else if outcome.effective != trimmed {
            // The environment takes precedence over the Keychain, so a variable left over in
            // this app's environment would shadow the key that was just saved. Say so rather
            // than report a save that will not be the one used.
            status = """
            Saved the \(reviewer.rawValue) API key, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is set in this app's environment \
            and takes precedence over it
            """
        } else {
            status = "Saved the \(reviewer.rawValue) API key to your Keychain"
        }
    }

    func removeAPIKey(for reviewer: ReviewerName) async {
        let outcome = await performCredentialWrite(for: reviewer) { store in
            try store.removeAPIKey(for: reviewer)
        }
        if let failure = outcome.failure {
            errorMessage = "Could not remove the \(reviewer.rawValue) API key: \(failure)"
            return
        }
        updateSavedKeyPanel(outcome, for: reviewer)
        // A key that still resolves after removal can only be coming from the environment,
        // and reporting a bare "Removed" would imply the reviewer had stopped being billed.
        if outcome.effective != nil {
            status = """
            Removed the \(reviewer.rawValue) API key from your Keychain, but \
            \(reviewer.apiKeyOverrideEnvironmentVariable) is still set in this app's \
            environment and will be used
            """
        } else {
            status = "Removed the \(reviewer.rawValue) API key from your Keychain"
        }
    }

    /// Performs one Keychain write off the main actor and reads back what it left in effect.
    private func performCredentialWrite(
        for reviewer: ReviewerName,
        _ body: @escaping @Sendable (any CredentialStoring) throws -> Void
    ) async -> CredentialWriteOutcome {
        let store = credentials
        return await Task.detached(priority: .userInitiated) {
            do {
                try body(store)
                return CredentialWriteOutcome(effective: store.apiKey(for: reviewer))
            } catch {
                return CredentialWriteOutcome(failure: error.localizedDescription)
            }
        }.value
    }

    /// Updates the panel from the write's own read-back rather than a second Keychain round
    /// trip, so a denied read cannot make the status line and the panel tell different stories.
    private func updateSavedKeyPanel(_ outcome: CredentialWriteOutcome, for reviewer: ReviewerName) {
        if outcome.effective == nil {
            reviewersWithSavedKey.remove(reviewer)
        } else {
            reviewersWithSavedKey.insert(reviewer)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        try? paths.prepare()
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    func openSettings() {
        let controller: NSWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let hostingController = NSHostingController(rootView: DashboardView(model: self))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Review Bot Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 800, height: 620))
            window.minSize = NSSize(width: 760, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ReviewBotSettingsWindow")

            controller = NSWindowController(window: window)
            settingsWindowController = controller

            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreAccessoryActivationPolicy()
                }
            }
        }

        // Review Bot runs as a menu-bar accessory (LSUIElement), so it must be promoted
        // to a regular app before AppKit will bring a standard window forward or make it key.
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func restoreAccessoryActivationPolicy() {
        NSApp.setActivationPolicy(.accessory)
    }

    var statusSymbol: String {
        if isRunning { return "arrow.triangle.2.circlepath" }
        if settings.configuration.isPaused { return "pause.circle.fill" }
        if history.entries.first?.kind == .failed { return "exclamationmark.circle.fill" }
        return "checkmark.bubble.fill"
    }

    private func schedulerLoop() async {
        while !Task.isCancelled {
            if settings.configuration.isPaused {
                if !isRunning { status = "Monitoring paused" }
            } else {
                let interval = TimeInterval(max(1, settings.configuration.pollIntervalMinutes) * 60)
                let pollIsDue = lastCheckDate.map { Date().timeIntervalSince($0) >= interval } ?? true
                if pollIsDue, !isRunning {
                    await performPoll()
                }
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func performPoll(manual: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            lastCheckDate = Date()
            // A poll reviews every request it discovers before returning, so nothing
            // should remain queued afterward. Reset defensively so a missed or
            // out-of-order terminal event can never leave a stale count in the menu bar.
            pendingReviews.removeAll()
            runningReviews.removeAll()
        }

        let configuration = settings.configuration
        await engine.poll(
            configuration: configuration,
            manual: manual,
            onEvent: { [weak self] entry in
                await MainActor.run {
                    self?.history.append(entry)
                    self?.updateQueue(for: entry)
                }
            },
            onStatus: { [weak self] value in
                await MainActor.run {
                    self?.status = value
                }
            }
        )
    }

    private func updateQueue(for entry: HistoryEntry) {
        guard let item = ReviewQueueItem(entry: entry) else { return }

        switch entry.kind {
        case .requestDetected:
            pendingReviews.removeAll(where: { $0.id == item.id })
            pendingReviews.append(item)
        case .reviewStarted:
            pendingReviews.removeAll(where: { $0.id == item.id })
            runningReviews.removeAll(where: { $0.id == item.id })
            runningReviews.append(item)
        case .approved, .changesRequested, .commented, .failed:
            pendingReviews.removeAll(where: { $0.id == item.id })
            runningReviews.removeAll(where: { $0.id == item.id })
        }
    }
}
