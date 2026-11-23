import SwiftUI

struct RootView: View {
    @Bindable var store: InboxStore
    var presentation: Presentation
    var actions: WindowActions

    var body: some View {
        Group {
            switch store.auth {
            case .checking:
                ProgressView("Connecting to GitHub…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut(let message):
                SignInView(store: store, message: message)
            case .signedIn:
                content
            }
        }
        .frame(minWidth: presentation == .window ? 760 : nil, maxWidth: .infinity,
               minHeight: presentation == .window ? 480 : nil, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                ToastView(store: store)
                UndoBar(store: store)
            }
            .padding(.bottom, 14)
        }
        .environment(\.presentation, presentation)
        .environment(\.windowActions, actions)
    }

    private var content: some View {
        HStack(spacing: 0) {
            InboxPane(store: store)
                .frame(width: store.focused != nil || presentation == .window ? 420 : nil)
            if let id = store.focused, let n = store.notification(id) {
                Divider()
                DetailPane(store: store, notification: n)
                    .id(id)
                    .frame(maxWidth: .infinity)
            } else if presentation == .window {
                Divider()
                EmptyDetail(store: store)
            }
        }
    }
}

private struct EmptyDetail: View {
    var store: InboxStore
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(store.visible.isEmpty ? "Nothing to triage" : "Select a notification")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                KeyHint(keys: "J  K", text: "move")
                KeyHint(keys: "E", text: store.scope == .done ? "move to inbox" : "done")
                KeyHint(keys: "?", text: "shortcuts")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeyHint: View {
    var keys: String
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct PresentationKey: EnvironmentKey { static let defaultValue = Presentation.popover }
private struct WindowActionsKey: EnvironmentKey { static let defaultValue = WindowActions(popOut: {}, settings: {}, dismiss: {}) }

extension EnvironmentValues {
    var presentation: Presentation {
        get { self[PresentationKey.self] }
        set { self[PresentationKey.self] = newValue }
    }
    var windowActions: WindowActions {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

/// Stays up for as long as a done/unsubscribe is waiting to be sent, whatever other messages come and go.
struct UndoBar: View {
    var store: InboxStore

    var body: some View {
        if let action = store.pending.last {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text(store.pending.count > 1 ? "\(action.title) (+\(store.pending.count - 1) more)" : action.title)
                    .font(.callout)
                Button("Undo") { store.undo(action.id) }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct ToastView: View {
    var store: InboxStore

    var body: some View {
        if let toast = store.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? GHColor.closed : GHColor.open)
                Text(toast.message)
                    .font(.callout)
                    .lineLimit(3)
                if let action = toast.undoable {
                    Button("Undo") { store.undo(action) }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .keyboardShortcut("z", modifiers: .command)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.undoable != nil ? store.prefs.undoSeconds : (toast.isError ? 6 : 2.5)))
                if store.toast?.id == toast.id { withAnimation { store.toast = nil } }
            }
        }
    }
}

struct SignInView: View {
    var store: InboxStore
    var message: String?
    @State private var token = ""
    @State private var working = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.full")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("GitHub Triage")
                .font(.title2.bold())
            Text("Sign in with the GitHub CLI (`gh auth login`), or paste a personal access token with the **notifications** and **repo** scopes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(GHColor.closed)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(save)
            HStack {
                Button("Create a token…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=notifications,repo&description=GitHub%20Triage")!)
                }
                Button("Try GitHub CLI again") { Task { await store.signIn() } }
                Button("Sign In", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        working = true
        Task {
            await store.signIn(token: t)
            working = false
        }
    }
}
