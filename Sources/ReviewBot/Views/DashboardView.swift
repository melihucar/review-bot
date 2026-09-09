import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, settings: model.settings)
                .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }

            ReviewersSettingsView(model: model, settings: model.settings)
                .tabItem { Label("Reviewers", systemImage: "sparkles") }

            DecisionPolicySettingsView(settings: model.settings)
                .tabItem { Label("Decisions", systemImage: "checklist") }

            PromptSettingsView(settings: model.settings)
                .tabItem { Label("Prompt", systemImage: "text.quote") }

            HistoryView(model: model, history: model.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .padding(16)
        .task { model.start() }
        .alert(
            "Review Bot couldn't complete that action",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Monitoring") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.configuration.isPaused ? "Monitoring is paused" : model.status)
                                .font(.headline)
                            Text("Run now always performs one check, even while automatic monitoring is paused.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(settings.configuration.isPaused ? "Resume" : "Pause") {
                            model.togglePaused()
                        }
                        .buttonStyle(.bordered)
                        Button("Run now") {
                            model.runNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                    }

                    Divider()

                    HStack {
                        Text("Check for review requests")
                        Picker("Check interval", selection: $settings.configuration.pollIntervalMinutes) {
                            Text("Every 5 minutes").tag(5)
                            Text("Every 15 minutes").tag(15)
                            Text("Every 30 minutes").tag(30)
                            Text("Every 1 hour").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Spacer()
                        if let date = model.lastCheckDate {
                            Text("Last checked \(date, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(
                            value: $settings.configuration.maxConcurrentReviews,
                            in: 1...8
                        ) {
                            Text(
                                settings.configuration.maxConcurrentReviews == 1
                                    ? "Review one pull request at a time"
                                    : "Review up to \(settings.configuration.maxConcurrentReviews) pull requests at once"
                            )
                        }
                        Text("Each pull request runs every enabled reviewer, so this many times that many CLI processes — and that much API traffic — can be in flight together. Pull requests from the same repository still prepare their worktrees one at a time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Launch Review Bot at login",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    .help("Available after Review Bot is packaged and placed in Applications.")
                }
                .padding(8)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repositories")
                        .font(.title3.weight(.semibold))
                    Text("Review Bot infers the GitHub repository from the folder's origin remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    chooseRepositoryFolder()
                } label: {
                    Label("Add repository", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if settings.configuration.repositories.isEmpty {
                ContentUnavailableView {
                    Label("No repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a local GitHub repository to start watching its review requests.")
                } actions: {
                    Button("Choose folder…") { chooseRepositoryFolder() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($settings.configuration.repositories) { $repository in
                        RepositoryRow(
                            repository: $repository,
                            onDelete: { settings.removeRepository(repository.id) }
                        )
                    }
                    .onDelete(perform: settings.removeRepositories)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    private func chooseRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a Git repository"
        panel.prompt = "Add Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.addRepository(folder: folder)
    }
}

private struct RepositoryRow: View {
    @Binding var repository: RepositoryConfiguration
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $repository.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(repository.enabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Display name", text: $repository.name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                HStack {
                    Text("GitHub")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    TextField("owner/repository", text: $repository.githubSlug)
                        .font(.caption.monospaced())
                }
                HStack(alignment: .top) {
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    Text(repository.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this repository from Review Bot")
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Remove \(repository.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove repository", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Review Bot stops watching this repository. Your local files are not affected.")
        }
    }
}

private struct ReviewersSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI reviewers")
                        .font(.title2.weight(.semibold))
                    Text("Enabled reviewers run independently in parallel. The most severe parsed verdict determines the GitHub action.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Review")
                                .frame(width: 70, alignment: .leading)
                            Picker("Review scope", selection: $settings.configuration.reviewScope) {
                                ForEach(ReviewScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        Text("“Whole PR” reviews the entire diff every time. “New changes only” reviews just what changed since the last posted review, so reviewers don't re-flag already-reviewed code — it falls back to the whole PR on the first review or a re-request with no new commits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("Review scope", systemImage: "arrow.left.and.right.text.vertical")
                }

                OptionalLimitBox(
                    title: "Re-review limit",
                    icon: "arrow.clockwise.circle",
                    toggleTitle: "Limit re-reviews per pull request",
                    defaultValue: 3,
                    range: 1...50,
                    stepperTitle: { "Review each pull request up to \($0) time\($0 == 1 ? "" : "s")" },
                    caption: { limit in
                        limit == nil
                            ? "Unlimited: every new commit or re-request is reviewed."
                            : "Counts reviews that were posted. After the limit is reached, further commits and re-requests on that PR are skipped."
                    },
                    limit: $settings.configuration.maxReviewRoundsPerPR
                )

                OptionalLimitBox(
                    title: "Failure budget",
                    icon: "exclamationmark.triangle",
                    toggleTitle: "Give up after repeated failures",
                    defaultValue: 5,
                    range: 1...20,
                    stepperTitle: { "Try a review request up to \($0) time\($0 == 1 ? "" : "s")" },
                    caption: { limit in
                        limit == nil
                            ? "A request whose reviewers keep failing is retried forever, with a widening delay between attempts."
                            : "A review that doesn't post — a reviewer errored, returned no verdict, or GitHub rejected the post — is retried with a widening delay, then abandoned. A new commit, a re-request, or Run now starts over."
                    },
                    limit: Binding(
                        get: { settings.configuration.failureBudget.limit },
                        set: { settings.configuration.failureBudget = FailureBudget(limit: $0) }
                    )
                )

                ToolStatusRow(
                    name: "GitHub CLI",
                    command: "gh",
                    isAvailable: model.toolAvailability["gh"] == true
                )

                ReviewerCard(
                    model: model,
                    reviewer: .claude,
                    icon: "brain.head.profile",
                    command: "claude",
                    configuration: $settings.configuration.claude,
                    efforts: ReviewEffort.claudeCases,
                    isAvailable: model.toolAvailability["claude"] == true
                )

                ReviewerCard(
                    model: model,
                    reviewer: .codex,
                    icon: "terminal.fill",
                    command: "codex",
                    configuration: $settings.configuration.codex,
                    efforts: ReviewEffort.codexCases,
                    isAvailable: model.toolAvailability["codex"] == true
                )

                ReviewerCard(
                    model: model,
                    reviewer: .opencode,
                    icon: "chevron.left.forwardslash.chevron.right",
                    command: "opencode",
                    configuration: $settings.configuration.opencode,
                    efforts: ReviewEffort.opencodeCases,
                    isAvailable: model.toolAvailability["opencode"] == true
                )

                HStack {
                    Text("At least one AI reviewer must be enabled. opencode is off by default; it runs the free `opencode/deepseek-v4-flash-free` model at max reasoning effort in a read-only sandbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh CLI status") {
                        Task { await model.refreshToolAvailability() }
                    }
                }
            }
            .padding(.top, 10)
        }
    }
}

/// A "limit this, or don't" setting: a toggle that flips an optional count between
/// off and a default, plus a stepper for the count. Used for the re-review limit and
/// the failure budget, which differ only in their numbers and their prose.
private struct OptionalLimitBox: View {
    let title: String
    let icon: String
    let toggleTitle: String
    let defaultValue: Int
    let range: ClosedRange<Int>
    let stepperTitle: (Int) -> String
    let caption: (Int?) -> String
    @Binding var limit: Int?

    private var isLimited: Binding<Bool> {
        Binding(
            get: { limit != nil },
            set: { limit = $0 ? defaultValue : nil }
        )
    }

    private var count: Binding<Int> {
        Binding(
            get: { limit ?? defaultValue },
            set: { limit = max(range.lowerBound, $0) }
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(toggleTitle, isOn: isLimited)

                if let limit {
                    Stepper(stepperTitle(limit), value: count, in: range)
                }

                Text(caption(limit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

private struct ReviewerCard: View {
    @ObservedObject var model: AppModel
    let reviewer: ReviewerName
    let icon: String
    let command: String
    @Binding var configuration: ReviewerConfiguration
    let efforts: [ReviewEffort]
    let isAvailable: Bool

    /// Small/experimental models with measurably weaker resistance to injected
    /// thread content (see the prompt-injection spike in issue #3).
    private static let smallModelMarkers = ["mimo", "laguna", "lightning", "big-pickle", "hy3", "mini"]

    private func isSmallModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return Self.smallModelMarkers.contains { name.contains($0) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable \(reviewer.rawValue)", isOn: $configuration.enabled)
                        .font(.headline)
                    Spacer()
                    ToolAvailabilityBadge(isAvailable: isAvailable, command: command)
                }

                HStack {
                    Text("Model")
                        .frame(width: 70, alignment: .leading)
                    TextField("Model name", text: $configuration.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                .disabled(!configuration.enabled)

                HStack {
                    Text("Effort")
                        .frame(width: 70, alignment: .leading)
                    Picker("Effort", selection: $configuration.effort) {
                        ForEach(efforts) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .disabled(!configuration.enabled)

                Divider()

                // Both modes have to be reachable for a picker to mean anything: a CLI to borrow
                // a login from, and a variable to deliver a key through. opencode has the first
                // and not the second, so it falls to the explanation below.
                if reviewer.supportsSessionAuth, let keyVariable = reviewer.apiKeyEnvironmentVariable {
                    HStack {
                        Text("Sign-in")
                            .frame(width: 70, alignment: .leading)
                        Picker("Sign-in", selection: $configuration.authMode) {
                            ForEach(ReviewerAuthMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .disabled(!configuration.enabled)

                    Text(configuration.authMode == .session
                        ? "Uses whatever `\(command)` is already logged in as. Review Bot sends no credentials."
                        : "Runs `\(command)` with `\(keyVariable)` set from your Keychain, billing that key instead of the CLI's own login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if configuration.authMode == .apiKey {
                        APIKeyRow(model: model, reviewer: reviewer)
                            .disabled(!configuration.enabled)
                    }
                } else {
                    // No picker to explain itself, so say where the credentials come from.
                    Text("Uses whatever `\(command)` is already logged in as. It takes no API key from Review Bot — its provider is chosen in its own configuration — so nothing it spends is billed to a key kept here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isSmallModel(configuration.model) {
                    Label(
                        "This model is small or experimental: it measurably degrades under adversarial pull-request content, so Review Bot gates its approvals behind injection checks (and never approves when a `VERDICT:` line appears in the thread or diff).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        } label: {
            Label(reviewer.rawValue, systemImage: icon)
        }
        .onChange(of: configuration.authMode) { _, _ in
            Task { await model.refreshSavedKeys() }
        }
    }
}

private struct APIKeyRow: View {
    @ObservedObject var model: AppModel
    let reviewer: ReviewerName
    @State private var draft = ""

    private var hasSavedKey: Bool { model.reviewersWithSavedKey.contains(reviewer) }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API key")
                    .frame(width: 70, alignment: .leading)
                SecureField(
                    hasSavedKey
                        ? "A key is saved — type a new one to replace it"
                        : "Paste your \(reviewer.rawValue) API key",
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let key = draft
                    draft = ""
                    Task { await model.saveAPIKey(key, for: reviewer) }
                }
                .disabled(trimmedDraft.isEmpty)
                Button("Remove", role: .destructive) {
                    Task { await model.removeAPIKey(for: reviewer) }
                }
                .disabled(!hasSavedKey)
            }

            Label(
                hasSavedKey
                    ? "Saved in your macOS Keychain, never in config.json."
                    : "No key saved. \(reviewer.rawValue) reviews will fail until you add one.",
                systemImage: hasSavedKey ? "key.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(hasSavedKey ? .green : .orange)
        }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let command: String
    let isAvailable: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: "point.3.connected.trianglepath.dotted")
            Spacer()
            ToolAvailabilityBadge(isAvailable: isAvailable, command: command)
        }
        .padding(.horizontal, 12)
    }
}

private struct ToolAvailabilityBadge: View {
    let isAvailable: Bool
    let command: String

    var body: some View {
        Label(
            isAvailable ? "\(command) found" : "\(command) not found",
            systemImage: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(isAvailable ? .green : .orange)
    }
}

private struct DecisionPolicySettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Decision policy")
                    .font(.title2.weight(.semibold))
                Text("Choose what Review Bot does on GitHub for each severity its reviewers report. When reviewers disagree across the request-changes line, Review Bot reconciles before deciding.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    DecisionRow(
                        verdict: "Blocking",
                        detail: "Always requests changes.",
                        selection: .constant(.requestChanges)
                    )
                    .disabled(true)

                    Divider()

                    DecisionRow(
                        verdict: "Should-fix",
                        detail: "Substantive issues that are not release-blocking.",
                        selection: $settings.configuration.decisionPolicy.shouldFix
                    )
                    DecisionRow(
                        verdict: "Nits only",
                        detail: "Minor, optional suggestions.",
                        selection: $settings.configuration.decisionPolicy.nitsOnly
                    )
                    DecisionRow(
                        verdict: "Clean",
                        detail: "No issues found.",
                        selection: $settings.configuration.decisionPolicy.clean
                    )
                }
                .padding(8)
            } label: {
                Label("When the strictest verdict is…", systemImage: "arrow.triangle.branch")
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("“Leave it to me” posts a neutral comment — no approval and no change request — so you make the call. A reviewer that fails or returns an unreadable verdict always falls back to a neutral comment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to defaults") {
                    settings.configuration.decisionPolicy = .default
                }
                .disabled(settings.configuration.decisionPolicy == .default)
            }

            Spacer()
        }
        .padding(.top, 10)
    }
}

private struct DecisionRow: View {
    let verdict: String
    let detail: String
    @Binding var selection: ReviewDecision

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)

            Picker("Action", selection: $selection) {
                ForEach(ReviewDecision.allCases) { decision in
                    Text(decision.actionLabel).tag(decision)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

private struct PromptSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom review instructions")
                    .font(.title2.weight(.semibold))
                Text("These instructions are appended to Review Bot's built-in review and verdict contract for every repository.")
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $settings.configuration.customPrompt)
                .font(.body.monospaced())
                .padding(8)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            HStack {
                Text("Examples: project-specific architecture rules, test commands, or areas to scrutinize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(settings.configuration.customPrompt.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    settings.configuration.customPrompt = ""
                }
                .disabled(settings.configuration.customPrompt.isEmpty)
            }
        }
        .padding(.top, 10)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity history")
                        .font(.title2.weight(.semibold))
                    Text("Review requests, starts, GitHub decisions, and failures are retained locally.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show data folder") { model.revealDataFolder() }
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            }

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock",
                    description: Text("Events will appear after Review Bot checks your repositories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 10)
        .confirmationDialog(
            "Clear all activity history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generated review files and detailed logs will remain on disk.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .font(.title3)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.kind.label)
                        .font(.headline)
                    if let number = entry.pullRequestNumber {
                        Text("\(entry.repositoryName) #\(number)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(entry.repositoryName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let title = entry.pullRequestTitle {
                    Text(title)
                        .font(.subheadline)
                }
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let value = entry.pullRequestURL, let url = URL(string: value) {
                    Link("Open PR", destination: url)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
