import SwiftUI

/// Installed sources and repository management.
struct SourcesScreen: View {
    @EnvironmentObject private var store: SourceStore
    @State private var showAdd = false
    @State private var busy: String?
    @State private var alert: String?

    var body: some View {
        List {
            Section(header: Text("Installed"), footer: Text(store.installed.isEmpty ? "" : "Swipe a source to the left to remove it.")) {
                if store.installed.isEmpty {
                    Text("No sources yet. Add a repository below, then install a source from it.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                ForEach(store.installed) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(source.name).font(Theme.serif(.title3, weight: .semibold))
                            ratingBadge(source.contentRating)
                        }
                        Text("Version \(source.version)").font(.caption).foregroundColor(.secondary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.uninstall(store.installed[i].id) }
                }
            }
            .listRowBackground(Theme.surface)

            ForEach(store.repos) { repo in
                Section(header: Text(repo.url).textCase(nil), footer: repoFooter(repo)) {
                    if repo.loading && repo.index == nil { ProgressView() }
                    if let index = repo.index {
                        ForEach(index.sources) { source in
                            sourceRow(source, repo: repo, compatible: index.isCompatible)
                        }
                    }
                    Button("Remove repository", role: .destructive) { store.removeRepo(repo.url) }
                }
                .listRowBackground(Theme.surface)
            }

            Section(footer: Text("Kumo ships with no sources. Nothing leaves this iPad except requests to the sites of sources you install. No analytics, no accounts.")) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add repository", systemImage: "plus")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sources")
        .sheet(isPresented: $showAdd) { AddRepoSheet() }
        .alert("Problem", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    @ViewBuilder
    private func repoFooter(_ repo: SourceStore.Repo) -> some View {
        if let error = repo.error {
            Text(error).foregroundColor(.orange)
        } else if let index = repo.index, !index.isCompatible {
            Text("Incompatible: this repository is not built for the 0.8 format, so its sources cannot run here.")
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func ratingBadge(_ rating: String?) -> some View {
        if let rating = rating, rating != "EVERYONE" {
            Text(rating == "ADULT" ? "18+" : "Mature")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(rating == "ADULT" ? Color.red.opacity(0.3) : Color.orange.opacity(0.3))
                .cornerRadius(4)
                .accessibilityLabel(rating == "ADULT" ? "Adult content" : "Mature content")
        }
    }

    private func sourceRow(_ source: RepoSource, repo: SourceStore.Repo, compatible: Bool) -> some View {
        let installedVersion = store.installedVersion(source.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(source.name)
                    ratingBadge(source.contentRating)
                }
                Text("\(source.version) · \(source.author ?? "unknown author")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !compatible {
                Text("Incompatible").font(.caption).foregroundColor(.orange)
            } else if busy == source.id {
                ProgressView()
            } else if installedVersion == source.version {
                Text("Installed").font(.caption).foregroundColor(.secondary)
            } else {
                Button(installedVersion == nil ? "Install" : "Update") {
                    busy = source.id
                    Task {
                        if let problem = await store.install(source, from: repo) { alert = problem }
                        busy = nil
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Sheet for adding a repository, with the third-party code warning.
struct AddRepoSheet: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = "https://"
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Repository address"),
                        footer: Text("Only https addresses are accepted.")) {
                    TextField("https://example.github.io/extensions/0.8", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section {
                    Label {
                        Text("You are adding third-party code. Sources are programs written by other people. Kumo runs each one in a sandbox with no access to your files or to other sources, but a source can see what you search and read on its own site. Only add repositories you trust.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.shield").foregroundColor(.orange)
                    }
                }
                if let problem = problem {
                    Section { Text(problem).foregroundColor(.orange) }
                }
                Section {
                    Button {
                        working = true
                        problem = nil
                        Task {
                            let result = await store.addRepo(address)
                            working = false
                            if let result = result { problem = result } else { dismiss() }
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Add repository") }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Add repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}
