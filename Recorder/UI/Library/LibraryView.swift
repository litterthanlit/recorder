import AppKit
import SwiftUI

/// Every recording, as a grid of cards: search, sort, open, rename, reveal, trash.
struct LibraryView: View {
    let appState: AppState
    @ObservedObject private var library: ProjectLibrary
    @State private var query = ""
    @State private var sort: ProjectSort = .newest
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""

    init(appState: AppState) {
        self.appState = appState
        library = appState.library
    }

    private var projects: [ProjectSummary] {
        sort.sorted(library.allProjects.filter { $0.matches(query) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.allProjects.isEmpty {
                emptyState
            } else if projects.isEmpty {
                noMatches
            } else {
                grid
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(DS.Palette.canvas)
        .onAppear { library.refresh() }
        .sheet(item: $renaming) { project in
            RenameSheet(name: $renameText, original: project.displayName) {
                library.rename(project, to: renameText)
                renaming = nil
            } onCancel: {
                renaming = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(DS.Typeface.largeTitle)
                Text(countLabel)
                    .font(DS.Typeface.footnote)
                    .foregroundStyle(DS.Palette.secondaryText)
            }
            Spacer()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityLabel("Search recordings")
            Picker("Sort", selection: $sort) {
                ForEach(ProjectSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                library.revealProjectsFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help("Show the projects folder in Finder")
            .accessibilityLabel("Show in Finder")
            Button {
                appState.chooseAndRecord()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(PrimaryButtonStyle(tint: DS.Palette.recording))
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    private var countLabel: String {
        let count = library.allProjects.count
        let total = library.allProjects.reduce(0) { $0 + $1.duration }
        return "\(count) recording\(count == 1 ? "" : "s") · \(RecentProjectsView.formattedDuration(total)) in all"
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: DS.Spacing.md)], spacing: DS.Spacing.md) {
                ForEach(projects) { project in
                    LibraryCard(project: project, library: library) {
                        appState.openProject(project)
                    }
                    .contextMenu {
                        Button("Open in Editor") { appState.openProject(project) }
                        Button("Rename…") {
                            renameText = project.name ?? ""
                            renaming = project
                        }
                        Button("Show in Finder") { library.reveal(project) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { appState.moveToTrash(project) }
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer()
            BrandMark(size: 56)
            Text("No recordings yet")
                .font(DS.Typeface.largeTitle)
            Text("Record an area, a window or a whole display. Every take lands here, ready to edit and export.")
                .font(DS.Typeface.body)
                .foregroundStyle(DS.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                appState.chooseAndRecord()
            } label: {
                Label("Record Your First Demo", systemImage: "record.circle")
            }
            .buttonStyle(PrimaryButtonStyle(tint: DS.Palette.recording))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: DS.Spacing.xs) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(DS.Palette.tertiaryText)
            Text("No recordings match “\(query)”")
                .font(DS.Typeface.title)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryCard: View {
    let project: ProjectSummary
    let library: ProjectLibrary
    let onOpen: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Color.primary.opacity(0.06)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 24))
                            .foregroundStyle(DS.Palette.tertiaryText)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))

                Text(RecentProjectsView.formattedDuration(project.duration))
                    .font(DS.Typeface.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(DS.Spacing.xs)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .strokeBorder(isHovering ? DS.Palette.accent : Color.primary.opacity(0.08), lineWidth: isHovering ? 2 : 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(DS.Typeface.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(project.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if project.hasExport {
                        Text("·")
                        Label("Exported", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(DS.Palette.success)
                    }
                }
                .font(DS.Typeface.caption)
                .foregroundStyle(DS.Palette.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .task(id: project.id) {
            thumbnail = await library.thumbnail(for: project)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.displayName), \(RecentProjectsView.formattedDuration(project.duration))\(project.hasExport ? ", exported" : "")")
        .accessibilityAction(named: Text("Open")) { onOpen() }
        .accessibilityAddTraits(.isButton)
    }
}

private struct RenameSheet: View {
    @Binding var name: String
    let original: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Rename Recording")
                .font(DS.Typeface.title)
            TextField(original, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.lg)
    }
}
