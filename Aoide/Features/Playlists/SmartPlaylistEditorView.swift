import CurationKit
import SwiftUI

/// Builds a smart playlist's rules, with a live count of what they'd catch.
///
/// The preview is the part that makes this usable rather than merely possible. A rule set
/// is a small program, and the only honest way to know whether it says what you meant is
/// to see what it returns — otherwise the first feedback arrives after saving, and an
/// empty playlist gives no clue which of four clauses was wrong. It costs nothing to
/// show: evaluation is one SQLite query against the local index, so it can run on every
/// keystroke without touching the network.
struct SmartPlaylistEditorView: View {
    /// `nil` when creating. Editing keeps the same playlist so its name, folder and id
    /// survive a rule change.
    let playlist: Playlist?
    let folderId: String?
    var onSave: (@MainActor (Playlist) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var indexer = SongIndexer.shared

    @State private var name = ""
    @State private var draft = SmartRulesDraft()
    @State private var preview: SmartPreview?
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    private var isEditing: Bool { playlist != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $name)
                }

                if !isEditing, draft.rules.isEmpty {
                    presetSection
                }

                rulesSection
                sortSection
                previewSection
            }
            .navigationTitle(isEditing ? "Edit Rules" : "Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                if let playlist {
                    name = playlist.name
                    if let rules = try? playlist.smartRuleSet() { draft = SmartRulesDraft(rules) }
                }
                // Rules can only match songs the local index knows about, and a brand new
                // install has none. Nothing happens here if it is already built.
                await indexer.indexIfNeeded(library: library)
            }
            // Re-runs whenever any part of the draft changes, and the previous run is
            // cancelled — which is what makes the sleep below a debounce rather than a
            // delay stacked on every keystroke.
            .task(id: draft) { await refreshPreview() }
            .alert(
                "That rule set won't work",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            ForEach(SmartPlaylistPreset.all) { preset in
                Button {
                    apply(preset)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            // `Color.primary`, not `.primary`. The hierarchical style
                            // resolves against whatever the container set, and inside a
                            // button that is the tint — so four preset rows would come
                            // out entirely violet, shouting over the covers everywhere
                            // else on screen.
                            Text(preset.name).foregroundStyle(Color.primary)
                            Text(preset.blurb)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Start From")
        } footer: {
            // Said out loud because the alternative reading — that presets are a separate,
            // sealed kind of playlist — is the one people assume.
            Text("These fill in the rules below. Change anything you like before creating it.")
        }
    }

    private func apply(_ preset: SmartPlaylistPreset) {
        guard let rules = try? preset.rules() else { return }
        draft = SmartRulesDraft(rules)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = preset.name }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            Picker("Match", selection: $draft.match) {
                Text("All rules").tag(SmartRules.Match.all)
                Text("Any rule").tag(SmartRules.Match.any)
            }
            .pickerStyle(.segmented)

            ForEach($draft.rules) { $rule in
                ruleEditor($rule)
            }
            .onDelete { draft.rules.remove(atOffsets: $0) }

            Button("Add Rule", systemImage: "plus.circle") {
                draft.rules.append(SmartRuleDraft())
            }
        } header: {
            Text("Rules")
        } footer: {
            if draft.rules.isEmpty {
                // `all` of nothing is every song, which is a real playlist when there's a
                // sort and a limit — "everything, top 25 by play count" — and a trap
                // otherwise. Better said than discovered.
                Text("With no rules this matches every song in your library. Add a sort and a limit below to make that useful.")
            } else if draft.rules.contains(where: { $0.op == .notInTheLast }) {
                Text("“is not in the last…” also matches songs you have never played.")
            }
        }
    }

    @ViewBuilder
    private func ruleEditor(_ rule: Binding<SmartRuleDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Picker("Field", selection: rule.field) {
                        ForEach(SmartField.all, id: \.self) { field in
                            Text(SmartField.name(of: field)).tag(field)
                        }
                    }
                } label: {
                    pill(SmartField.name(of: rule.wrappedValue.field))
                }
                .onChange(of: rule.wrappedValue.field) { _, _ in
                    // A field change can leave an operator the new field cannot take. The
                    // draft repairs itself rather than letting the rule fail to convert
                    // with an error naming a pair nobody chose.
                    rule.wrappedValue.fieldDidChange()
                }

                Menu {
                    Picker("Operator", selection: rule.op) {
                        ForEach(rule.wrappedValue.kind.operators, id: \.self) { op in
                            Text(SmartField.name(of: op)).tag(op)
                        }
                    }
                } label: {
                    pill(SmartField.name(of: rule.wrappedValue.op))
                }

                Spacer(minLength: 0)
            }

            valueEditor(rule)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartRuleDraft>) -> some View {
        switch rule.wrappedValue.kind {
        case .text:
            TextField("Value", text: rule.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()

        case .number:
            HStack {
                TextField("0", value: rule.number, format: .number)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 64)
                if let unit = SmartField.unit(of: rule.wrappedValue.field) {
                    Text(unit).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        case .date:
            HStack {
                TextField("30", value: rule.intervalAmount, format: .number)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 70)
                Picker("Unit", selection: rule.intervalUnit) {
                    ForEach(RelativeInterval.Unit.allCases, id: \.self) { unit in
                        Text(SmartField.name(of: unit, plural: rule.wrappedValue.intervalAmount != 1))
                            .tag(unit)
                    }
                }
                .labelsHidden()
                Spacer(minLength: 0)
            }

        case .flag:
            Toggle("Yes", isOn: rule.flag)
        }
    }

    private func pill(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: .capsule)
    }

    // MARK: - Sort and limit

    private var sortSection: some View {
        Section {
            Toggle("Sort the results", isOn: $draft.isSorted)
            if draft.isSorted {
                Picker("By", selection: $draft.sortField) {
                    ForEach(SmartRulesDraft.sortableFields, id: \.self) { field in
                        Text(SmartField.name(of: field)).tag(field)
                    }
                }
                Picker("Order", selection: $draft.sortDescending) {
                    Text("Highest first").tag(true)
                    Text("Lowest first").tag(false)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Limit the number of songs", isOn: $draft.isLimited)
            if draft.isLimited {
                Stepper("Keep \(draft.limit) songs", value: $draft.limit, in: 1...500, step: 5)
            }
        } header: {
            Text("Order")
        } footer: {
            if draft.isLimited && !draft.isSorted {
                // Without an order a limit takes an arbitrary subset, and the package
                // falls back to sorting by title so the same rules at least return the
                // same songs twice running. Worth saying, because "top 25" without a sort
                // is what everybody means and not what it does.
                Text("With no sort, a limit keeps the first songs alphabetically — probably not what you meant.")
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            if indexer.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(indexingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let preview {
                if let message = preview.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Matches \(preview.count) song\(preview.count == 1 ? "" : "s") right now")
                        .font(.subheadline.weight(.medium))
                    ForEach(Array(preview.titles.enumerated()), id: \.offset) { _, title in
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if preview.count > preview.titles.count {
                        Text("and \(preview.count - preview.titles.count) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Working it out…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var indexingMessage: String {
        if case .running(let indexed) = indexer.state {
            return "Indexing your library — \(indexed) songs so far"
        }
        return "Indexing your library"
    }

    private func refreshPreview() async {
        // A debounce, not a delay: `.task(id:)` cancels the previous run on every change,
        // so this only ever completes for the last edit in a burst of typing.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            preview = await playlists.preview(try draft.build())
        } catch {
            preview = SmartPreview(count: 0, titles: [], errorMessage: LocalPlaylistStore.describe(error))
        }
    }

    // MARK: - Saving

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let rules: SmartRules
        do {
            rules = try draft.build()
        } catch {
            errorMessage = LocalPlaylistStore.describe(error)
            return
        }

        if let playlist {
            await playlists.setRules(rules, on: playlist)
            if playlist.name != trimmed { await playlists.rename(playlist, to: trimmed) }
            // Handed back rather than re-read: the caller is showing this playlist and
            // needs the new name and rules on screen, and a second query would be one more
            // thing that can be out of date.
            if var updated = try? playlist.settingSmartRules(rules) {
                updated.name = trimmed
                onSave?(updated)
            }
        } else {
            let created = await playlists.createSmartPlaylist(name: trimmed, rules: rules, folderId: folderId)
            if let created { onSave?(created) }
        }
        dismiss()
    }
}
