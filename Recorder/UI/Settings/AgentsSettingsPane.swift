import AppKit
import SwiftUI

/// Settings › Agents: let AI agents (Claude Code, Claude Desktop, Cursor) edit recordings
/// through `Trace --mcp`, and how to connect one.
struct AgentsSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var bridge: AgentBridgeController

    var body: some View {
        Form {
            accessSection
            AgentConnectSection()
            AgentPromptSection()
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
    }

    private var accessSection: some View {
        Section {
            Toggle("Allow AI agents to edit recordings", isOn: $settings.settings.agentAccessEnabled)
            AgentStatusRow(status: bridge.status)
        } header: {
            Text("Access")
        } footer: {
            Text("Agents running on this Mac as you can list, view, edit and export your takes. Each edit is a normal step you can undo with ⌘Z. Nothing leaves your Mac unless your agent sends it.")
        }
    }
}

private struct AgentStatusRow: View {
    let status: AgentBridgeController.Status

    var body: some View {
        LabeledContent("Status") {
            Label(text, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(DS.Typeface.footnote)
                .foregroundStyle(color)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch status {
        case .off:
            return "Off"
        case let .listening(agents):
            return agents == 0 ? "Ready for agents" : "\(agents) agent\(agents == 1 ? "" : "s") connected"
        case let .failed(message):
            return "Couldn't start: \(message)"
        }
    }

    private var symbol: String {
        switch status {
        case .off: return "circle"
        case .listening: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .off: return DS.Palette.secondaryText
        case .listening: return DS.Palette.success
        case .failed: return DS.Palette.warning
        }
    }
}

private struct AgentConnectSection: View {
    @State private var copied: String?

    private var executable: String {
        Bundle.main.executablePath ?? "/Applications/Trace.app/Contents/MacOS/Trace"
    }

    var body: some View {
        Section {
            AgentSnippetRow(
                title: "Claude Code",
                snippet: AgentSetup.claudeCodeCommand(executable: executable),
                copyLabel: "Copy Command",
                copied: $copied
            )
            AgentSnippetRow(
                title: "Claude Desktop, Cursor and others",
                snippet: AgentSetup.clientConfig(executable: executable),
                copyLabel: "Copy JSON",
                copied: $copied
            )
        } header: {
            Text("Connect an agent")
        } footer: {
            Text("Claude Code: paste the command into Terminal. Claude Desktop: Settings › Developer › Edit Config, add the server, then restart it. Trace starts in the background when an agent needs it.")
        }
    }
}

private struct AgentPromptSection: View {
    @State private var copied: String?

    var body: some View {
        Section {
            AgentSnippetRow(
                title: "Ask your agent",
                snippet: AgentSetup.examplePrompt,
                copyLabel: "Copy",
                copied: $copied,
                monospaced: false
            )
        } header: {
            Text("Try it")
        } footer: {
            Text("Agents can also use the launch_demo prompt, which walks them through analyzing, cutting, styling and exporting a take.")
        }
    }
}

private struct AgentSnippetRow: View {
    let title: String
    let snippet: String
    let copyLabel: String
    @Binding var copied: String?
    var monospaced = true

    private var isCopied: Bool {
        copied == snippet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(title)
                    .font(DS.Typeface.headline)
                Spacer()
                Button(isCopied ? "Copied" : copyLabel, action: copy)
                    .accessibilityLabel("\(copyLabel): \(title)")
            }
            Text(snippet)
                .font(monospaced ? Font.system(size: 11, design: .monospaced) : DS.Typeface.body)
                .foregroundStyle(DS.Palette.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.raisedSurface, in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .padding(.vertical, DS.Spacing.xxs)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copied = snippet
    }
}
