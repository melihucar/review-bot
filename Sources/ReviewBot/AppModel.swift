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
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var pendingReviews: [ReviewQueueItem] = []
    @Published private(set) var runningReview: ReviewQueueItem?
    @Published var errorMessage: String?

    let settings: SettingsStore
    let history: HistoryStore

    private let paths: StoragePaths
    private let runner: any CommandRunning
    private let engine: ReviewEngine
    private var schedulerTask: Task<Void, Never>?
    private var settingsWindowController: NSWindowController?
    private var hasStarted = false

    init(paths: StoragePaths = StoragePaths()) {
        self.paths = paths
        runner = ProcessRunner()
        settings = SettingsStore(paths: paths)
        history = HistoryStore(paths: paths)
        engine = ReviewEngine(paths: paths, runner: runner)
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
            await self?.performPoll()
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
        for tool in ["gh", "claude", "codex"] {
            let result = try? await runner.run("which", arguments: [tool], timeout: 10)
            statuses[tool] = result?.succeeded == true
        }
        toolAvailability = statuses
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

    private func performPoll() async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            lastCheckDate = Date()
            // A poll reviews every request it discovers before returning, so nothing
            // should remain queued afterward. Reset defensively so a missed or
            // out-of-order terminal event can never leave a stale count in the menu bar.
            pendingReviews.removeAll()
            runningReview = nil
        }

        let configuration = settings.configuration
        await engine.poll(
            configuration: configuration,
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
            runningReview = item
        case .approved, .changesRequested, .commented, .failed:
            pendingReviews.removeAll(where: { $0.id == item.id })
            if runningReview?.id == item.id {
                runningReview = nil
            }
        }
    }
}
