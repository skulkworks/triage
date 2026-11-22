# GitHub Triage (ght)

A menu-bar inbox for GitHub notifications on macOS 26+. It does what the github.com inbox does (read, done, save, unsubscribe, filters) and lets you read the whole conversation and act on it without opening a browser: reply, close or reopen with a reason, merge, approve, label, assign yourself, react.

## Using it

- Click the tray icon in the menu bar, or press ⌃⌥G from any app. Right-click the icon for Refresh, Open in Window, Settings and Quit.
- If a menu-bar manager (Hidden Bar, Bartender, Ice) hides the icon, the inbox opens as a window instead.
- Sign-in uses the GitHub CLI's login (`gh auth login`) automatically, or a personal access token saved in the Keychain (classic tokens need the `notifications` and `repo` scopes).

Keyboard: j/k move, ↩ open, e or ⌫ done, ⇧I read, s save, z snooze until tomorrow, ⇧U unsubscribe, o open on github.com, r reply, ⌘↩ send, ⇧⌘↩ close with comment, ⌘Z undo, ⌘F filter, ⌘R refresh, esc close, ? shortcuts.

## Beyond the web inbox

- **Undo**: done and unsubscribe wait a few seconds (configurable) before they're sent, so ⌘Z works. GitHub's API has no "undone".
- **Tidy menu** (wand icon): mark whole groups done at once: closed and merged threads, everything read, releases, bot activity, CI.
- **Snooze**: hide a thread until later. New activity on it brings it back early.
- **Saved filters** using GitHub-style queries: `repo:getgrav/grav reason:mention,assign is:open -is:release crash`.
- **"New since you last read"** divider in the conversation, and it scrolls there.
- **Snippets** (saved replies) in the reply box, quote-reply and @mention from any comment.
- Links to issues or PRs that are also in the inbox open in the app.
- macOS notifications for new activity (choose which reasons), with Done and Mark as read on the banner.

GitHub's API can't mark a thread unread or list done threads, so those two web features aren't here.

## Building

```sh
xcodegen generate
xcodebuild -project GHT.xcodeproj -scheme GHT -configuration Debug -derivedDataPath build/DerivedData build
```

Debug builds are "GitHub Triage Dev" (`dev.skulkworks.ght.debug`) with their own Keychain item and settings. `-ghtSelfTest -ghtOut <dir>` runs read-only checks against the signed-in account and writes rendered conversations to `<dir>`. `-ghtWindow`, `-ghtShowOnLaunch` and `-ghtOpenThread <id>` are for screenshots.
