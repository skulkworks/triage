import SwiftUI

struct Composer: View {
    var store: InboxStore
    var notification: GHNotification
    var subject: GQLSubject
    @Binding var draft: String
    @FocusState private var focused: Bool
    @Environment(\.windowActions) private var windowActions

    private var id: String { notification.id }
    private var sending: Bool { store.busy.contains(id) }
    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isOpen: Bool { subject.state == "OPEN" || (subject.__typename == "Discussion" && subject.closed != true) }
    private var canChangeState: Bool { isOpen ? (subject.viewerCanClose ?? subject.viewerCanUpdate ?? false) : (subject.viewerCanReopen ?? subject.viewerCanUpdate ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: focused || !draft.isEmpty ? 90 : 38, maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.isEmpty {
                    Text(subject.locked == true ? "Conversation is locked" : "Reply… Markdown works, ⌘↩ sends")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: focused ? 1.5 : 0.5))
            .animation(.snappy(duration: 0.15), value: focused)

            HStack(spacing: 8) {
                snippets
                Spacer()
                Group {
                    if subject.__typename == "PullRequest", subject.state == "OPEN" { reviewMenu }
                    if canChangeState { stateButton }
                }
                .disabled(sending)
                Button {
                    send(nil)
                } label: {
                    if sending { ProgressView().controlSize(.small) } else { Text("Comment") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty || sending)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .onChange(of: store.replyFocusRequest) { focused = true }
    }

    private var snippets: some View {
        Menu {
            ForEach(store.local.snippets) { s in
                Button(s.name) {
                    draft = draft.isEmpty ? s.body : draft + "\n\n" + s.body
                    focused = true
                }
            }
            Divider()
            Button("Edit Snippets…") { windowActions.settings() }
        } label: {
            Label("Snippets", systemImage: "text.bubble")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a saved reply")
    }

    @ViewBuilder private var stateButton: some View {
        if isOpen {
            if subject.__typename == "Issue" {
                Menu {
                    ForEach(CloseReason.allCases) { reason in
                        Button(isEmpty ? reason.label : reason.label.replacingOccurrences(of: "Close", with: "Comment and close")) {
                            send(.close(reason))
                        }
                    }
                } label: {
                    Text(isEmpty ? "Close issue" : "Close with comment")
                } primaryAction: {
                    send(.close(.completed))
                }
                .fixedSize()
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("⇧⌘↩ closes as completed; the arrow has other reasons")
            } else {
                Button(isEmpty ? "Close" : "Close with comment") { send(.close(.completed)) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        } else if subject.state != "MERGED" {
            Button(isEmpty ? "Reopen" : "Reopen with comment") { send(.reopen) }
        }
    }

    private var reviewMenu: some View {
        Menu("Review") {
            Button("Approve") { review("APPROVE") }
            Button("Request changes") { review("REQUEST_CHANGES") }.disabled(isEmpty)
            Button("Comment as review") { review("COMMENT") }.disabled(isEmpty)
        }
        .fixedSize()
        .help("Submit a review, using the text above as its body")
    }

    private func send(_ change: InboxStore.StateChange?) {
        let body = draft
        Task {
            if await store.reply(id, body: body, then: change) {
                if draft == body { draft = "" }
            }
        }
    }

    private func review(_ event: String) {
        let body = draft
        Task {
            if await store.review(id, event: event, body: body), draft == body { draft = "" }
        }
    }
}
