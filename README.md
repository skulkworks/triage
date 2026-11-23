# Triage

A menu-bar inbox for GitHub notifications on macOS 26+. It does what the github.com inbox does (read, done, save, unsubscribe, filters) and lets you read the whole conversation and act on it without opening a browser: reply, close or reopen with a reason, merge, approve, label, assign yourself, react.

## Using it

- Click the tray icon in the menu bar, or press ⌃⌥G from any app. Right-click the icon for Refresh, Open in Window, Settings and Quit.
- If a menu-bar manager (Hidden Bar, Bartender, Ice) hides the icon, the inbox opens as a window instead.
- Sign-in uses the GitHub CLI's login (`gh auth login`) automatically, or a personal access token saved in the Keychain (classic tokens need the `notifications` and `repo` scopes).

Keyboard: j/k move, ↩ open, e or ⌫ done (in the Done tab, move back to the inbox), ⇧I read, ⇧U unread (in the app only, see below), s save, z snooze until tomorrow, ⇧M unsubscribe, o open on github.com, r reply, ⌘↩ send, ⇧⌘↩ close with comment, ⌘Z undo, ⌘F filter, ⌘R refresh, esc close, ? shortcuts.

## Beyond the web inbox

- **Undo**: done and unsubscribe wait a few seconds (configurable) before they're sent, so ⌘Z works.
- **Done tab**: your most recent 200 done threads, for finding one you cleared too early. Open, read and reply as usual, or move it back to the inbox (see below).
- **Tidy menu** (wand icon): mark whole groups done at once: closed and merged threads, everything read, releases, bot activity, CI.
- **Snooze**: hide a thread until later. New activity on it brings it back early.
- **Saved filters** using GitHub-style queries: `repo:getgrav/grav reason:mention,assign is:open -is:release crash`.
- **"New since you last read"** divider in the conversation, and it scrolls there.
- **Snippets** (saved replies) in the reply box, quote-reply and @mention from any comment.
- Links to issues or PRs that are also in the inbox open in the app.
- macOS notifications for new activity (choose which reasons), with Done and Mark as read on the banner.

GitHub's API can't mark a thread unread or move a done thread back to the inbox, so both work inside the app only. A thread marked unread shows as unread here (and counts in the badge) until you open or read it, but github.com still shows it as read. A thread moved to the inbox stays in the app's inbox until you mark it done again, but github.com still shows it as done. New activity on the thread puts it back in GitHub's inbox anyway.

## Building

```sh
xcodegen generate
xcodebuild -project Triage.xcodeproj -scheme Triage -configuration Debug -derivedDataPath build/DerivedData build
```

Debug builds are "Triage Dev" (`dev.skulkworks.triage.debug`) with their own Keychain item and settings. `-triageSelfTest -triageOut <dir>` runs read-only checks against the signed-in account and writes rendered conversations to `<dir>`. `-triageWindow`, `-triageShowOnLaunch`, `-triageOpenThread <id>`, `-triageScope <tab>` and `-triageAppearance light|dark` are for screenshots.
