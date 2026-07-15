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

                ToolStatusRow(
                    name: "GitHub CLI",
                    command: "gh",
                    isAvailable: model.toolAvailability["gh"] == true
                )

                ReviewerCard(
                    title: "Claude",
                    command: "claude",
                    configuration: $settings.configuration.claude,
                    efforts: ReviewEffort.claudeCases,
                    isAvailable: model.toolAvailability["claude"] == true
                )

                ReviewerCard(
                    title: "Codex",
                    command: "codex",
                    configuration: $settings.configuration.codex,
                    efforts: ReviewEffort.codexCases,
                    isAvailable: model.toolAvailability["codex"] == true
                )

                HStack {
                    Text("At least one AI reviewer must be enabled.")
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

private struct ReviewerCard: View {
    let title: String
    let command: String
    @Binding var configuration: ReviewerConfiguration
    let efforts: [ReviewEffort]
    let isAvailable: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable \(title)", isOn: $configuration.enabled)
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
            }
            .padding(8)
        } label: {
            Label(title, systemImage: title == "Claude" ? "brain.head.profile" : "terminal.fill")
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
