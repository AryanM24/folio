import FolioAgent
import FolioKit
import SwiftUI

/// Settings > Agents: register Folio's MCP server with agent apps and install the `folio`
/// command. Every change to another app's config is shown first and needs a click.
struct AgentsSettings: View {
    @State private var connected: Set<Connect.Client> = []
    @State private var pending: Connect.Plan?
    @State private var notice: (title: String, message: String)?
    @State private var working: Connect.Client?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use Folio from AI agents")
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    "Agents like Claude Code can convert, compress and read files on this Mac through Folio. Files stay on your Mac, and Folio only ever writes new files."
                )
                .foregroundStyle(Hero.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Connect.targets) { client in
                    row(client)
                    if client != Connect.targets.last { Divider().overlay(Hero.separator).padding(.horizontal, 12) }
                }
            }
            .heroCard(padding: 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Command line").fontWeight(.medium)
                        Text("Adds folio to ~/.local/bin for use in Terminal.")
                            .font(.system(size: 12))
                            .foregroundStyle(Hero.muted)
                    }
                    Spacer()
                    Button("Install folio command", action: install)
                        .buttonStyle(.hero(.tertiary, size: .sm))
                }
                HStack(spacing: 8) {
                    Text(Connect.claudeCommand())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Hero.muted)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                        .help("Copy the Claude Code setup command")
                }
                .padding(10)
                .background(Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.xl))
            }
            .heroCard(padding: 12)
        }
        .font(.system(size: 13))
        .onAppear(perform: refresh)
        .alert(
            "Connect \(pending?.client.title ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { plan in
            Button("Connect") { apply(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(([plan.summary] + plan.warnings).joined(separator: "\n\n"))
        }
        .alert(
            notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private func row(_ client: Connect.Client) -> some View {
        let isConnected = connected.contains(client)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.title).fontWeight(.medium)
                Text(isConnected ? "Folio is set up" : "Not set up")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
            }
            Spacer()
            if working == client {
                ProgressView().controlSize(.small)
            } else if isConnected {
                HeroChip("Connected", tone: .success)
            }
            Button(isConnected ? "Update" : "Connect") { connect(client) }
                .buttonStyle(.hero(isConnected ? .tertiary : .secondary, size: .sm))
                .disabled(working != nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: Actions

    private func refresh() {
        connected = Set(Connect.targets.filter { Connect.isConnected($0) })
    }

    private func connect(_ client: Connect.Client) {
        do {
            let plan = try Connect.plan(for: client)
            switch plan.action {
            case .none: notice = (client.title, plan.summary)
            case .manual: notice = ("Run one command", plan.summary)
            case .run, .write: pending = plan
            }
        } catch {
            notice = ("Couldn't connect \(client.title)", error.localizedDescription)
        }
    }

    private func apply(_ plan: Connect.Plan) {
        working = plan.client
        Task {
            // `claude mcp add` is a subprocess; keep it off the main thread.
            let result = await Task.detached { Result { try Connect.apply(plan) } }.value
            working = nil
            refresh()
            switch result {
            case .success(let message): notice = ("\(plan.client.title) connected", message)
            case .failure(let error): notice = ("Couldn't connect \(plan.client.title)", error.localizedDescription)
            }
        }
    }

    private func install() {
        do {
            notice = ("folio command", try Connect.install())
        } catch {
            notice = ("Couldn't install the folio command", error.localizedDescription)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Connect.claudeCommand(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
