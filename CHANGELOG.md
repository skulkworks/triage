# Changelog

## 0.1.1 (2026-11-27, build 2)

### Improved
- Threads you've already opened now pick up changes made elsewhere (a comment from the browser or the CLI, a label, a close) without a manual refresh: Triage checks them against GitHub when you open one, on every poll and when the window comes forward

### Fixed
- Clicking a row that was still selected after closing its thread did nothing

## 0.1.0 (2026-11-22, build 1)

### New
- First release: your GitHub notifications inbox in the menu bar, with the whole conversation, replies and triage actions without opening a browser
- Done, Save, Snooze, Unsubscribe and Mark as read or unread, with undo, keyboard shortcuts and bulk actions
- Done tab for finding threads you cleared too early, with Move to Inbox
- Filters by repo, org, reason, state, label and author, plus saved filters
- Conversations are fetched ahead of time, so threads open instantly
- macOS notifications for new activity, a global hotkey and launch at login
