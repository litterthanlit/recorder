import AppKit
import SwiftUI

/// The last few recordings, newest first, for the menu bar panel.
///
/// Rows are compact (a 16:10 thumbnail, title, relative date, duration) so the panel stays
/// scannable. Every action is available three ways: the visible ⋯ menu, the right-click
/// menu, and VoiceOver actions.
struct RecentProjectsView: View {
    @ObservedObject var library: ProjectLibrary
    var onOpen: (ProjectSummary) -> Void
    var onTrash: (ProjectSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Show All") {
                    library.revealProjectsFolder()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Open the Recorder folder in Finder")
            }

            if library.recentProjects.isEmpty {
                Text("Recordings you make will show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(library.recentProjects) { project in
                        RecentProjectRow(
                            project: project,
                            library: library,
                            onOpen: { onOpen(project) },
                            onTrash: { onTrash(project) }
                        )
                    }
                }
            }
        }
    }
}

private struct RecentProjectRow: View {
    let project: ProjectSummary
    let library: ProjectLibrary
    let onOpen: () -> Void
    let onTrash: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    thumbnailView

                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 4) {
                            Text(project.createdAt, format: .relative(presentation: .named))
                            if project.hasExport {
                                Text("·")
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Exported")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(Self.formattedDuration(project.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in the editor")
            .accessibilityLabel(accessibilityDescription)
            .accessibilityHint("Opens the recording in the editor")
            .accessibilityAction(named: Text("Show in Finder")) { library.reveal(project) }
            .accessibilityAction(named: Text("Move to Trash"), onTrash)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.55)
            .accessibilityLabel("More actions for \(project.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .task(id: project.id) {
            thumbnail = await library.thumbnail(for: project)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open in Editor", action: onOpen)
        Button("Show in Finder") { library.reveal(project) }
        Divider()
        Button("Move to Trash", role: .destructive, action: onTrash)
    }

    private var thumbnailView: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var accessibilityDescription: String {
        var parts = [
            project.title,
            "\(Self.formattedDuration(project.duration)) long",
            "recorded \(project.createdAt.formatted(.relative(presentation: .named)))"
        ]
        if project.hasExport {
            parts.append("exported")
        }
        return parts.joined(separator: ", ")
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
