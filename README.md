# MailAsyncAccountsFix

Staggered account fetching for Apple Mail on macOS. It works around a
deadlock that can occur when Mail has many IMAP accounts.

> **Unofficial workaround.** This is not an Apple tool. It relies on one
> undocumented Mail preference and on Mail's AppleScript support. It can
> stop working after a macOS or Mail update. Use at your own risk.

## The problem

With many IMAP accounts (in our case about 35–40), Apple Mail regularly
stops working:

- Message bodies stay blank or white.
- Mailboxes stop loading.
- The app never recovers and has to be force-quit.

A `sample` of the stuck process showed a thread-starvation deadlock:

```
Dispatch Thread Soft Limit: 64 reached in 6664 of 6664 samples
-- too many dispatch threads blocked in synchronous operations
```

| Threads | Doing                                                              | Waiting for                     |
|--------:|--------------------------------------------------------------------|---------------------------------|
| 37      | `-[MFIMAPAccount _synchronizeMailboxListDuringMailCheck]`           | an IMAP connection              |
| 26      | `-[IMAPTaskManager _createNewConnectionSynchronously:isFirstConnection:]` | a free worker thread       |
| 1       | `-[IMAPTaskManager expungeMailbox:ifSelected:]`                     | an IMAP connection              |

The main thread is idle, and no thread is doing network I/O. Every thread
is blocked waiting.

**Cause.** A mail check starts a mailbox-list sync for every account at the
same time. Each sync blocks a thread while it waits for a connection. The
connection setup itself needs a worker thread, and all 64 are already taken
by the waiting syncs. Nothing can make progress.

Environment where this was observed: macOS 26.6.2 (25G83), Mail 16.0
(3864.700.51.1.1), Apple Silicon, ~275,000 messages.

## What this tool does

The fix is to make sure Mail never checks all accounts at once.

| Step | Change | Effect |
|------|--------|--------|
| 1 | `AutoFetch = NO` | Sets "Check for new messages" to **Manually**, so there is no timer-driven fetch of all accounts. |
| 2 | `DisableSynchronizationOnAppActivation = YES` | Hidden preference: no fetch of all accounts when Mail comes to the foreground. |
| 3 | LaunchAgent | Every **10 minutes**, checks the enabled accounts **one after another**, with a **10-second** pause between accounts. |

IMAP push (IDLE) is not touched. Mail still notifies about new inbox
messages per account, and that path is already per-account.

The background service:

- Only runs while Mail is open. It never launches Mail.
- Uses a lock, so two rounds never overlap.
- Writes a small log file.

### Where the hidden preference comes from

`DisableSynchronizationOnAppActivation` is not documented. It appears in
the Mail binary next to `AutoFetch` and `PollTime`, in the `AccountManager`
code. The binary also contains this log message:

```
Application became active more than 60 seconds since last user
interaction-triggered fetch, performing automatic fetch
```

That message also appeared in our logs. Its effect is inferred from the
binary, not confirmed by Apple. Option 3 (Status) checks the system log so
you can verify it on your machine.

## Requirements

- macOS with Apple Mail (tested on macOS 26.x)
- **Full Disk Access** for Terminal
  (System Settings → Privacy & Security → Full Disk Access)
- **Automation** permission for Terminal → Mail. macOS asks on first run.
  The background service may also trigger a prompt for `bash` or
  `osascript`. Allow it.

## Usage

1. Download `MailAsyncAccountsFix.command`.
2. Remove the quarantine flag. Files downloaded from the internet are
   marked by macOS, and Gatekeeper then refuses to run the unsigned
   script ("cannot be opened because it is from an unidentified
   developer"). This removes the mark:
   ```bash
   sudo xattr -rd com.apple.quarantine /path/to/MailAsyncAccountsFix.command
   ```
   Tip: type `sudo xattr -rd com.apple.quarantine ` (with a trailing
   space) and drag the file into the Terminal window to insert its path.
3. Start the script from Terminal:
   ```bash
   bash /path/to/MailAsyncAccountsFix.command
   ```
   Running it with `bash` works even if the file is not marked as
   executable, so `chmod +x` is not needed. (Alternatively: run
   `chmod +x` once and then double-click the file.)
4. Choose an option:

```
  1) Install
  2) Uninstall (restore everything)
  3) Status / check
  4) Cancel
```

**Install** quits Mail, backs up the current preference values, applies the
changes, installs the LaunchAgent, restarts Mail and tests AppleScript
access.

**Uninstall** removes the LaunchAgent and restores the backed-up preference
values. If no backup exists, it deletes the keys, which brings back Mail's
default behavior.

**Status** shows:

- whether the service is active
- the current preference values
- whether Mail answers AppleScript
- the last log entries
- whether Mail still started a fetch of all accounts in the last 2 hours

After installing, check Mail → Settings → General: "Check for new
messages" should show **Manually**.

## Configuration

Edit the top of the script before installing:

```bash
INTERVAL_MIN=10   # start a new round every N minutes
PAUSE_SEC=10      # pause between two accounts
```

One round takes about `accounts × (PAUSE_SEC + fetch time)`. With ~40
accounts and the defaults, a round fits comfortably into 10 minutes. If a
round is still running, the next one is skipped.

To change the values after installing, uninstall, edit the script, then
install again.

## Files

| Path | Purpose |
|------|---------|
| `~/Library/LaunchAgents/com.github.arturfromtheblock.mail-async-accounts-fix.plist` | LaunchAgent |
| `~/Library/Application Support/MailAsyncAccountsFix/fetch-staggered.sh` | Worker script |
| `~/Library/Application Support/MailAsyncAccountsFix/backup.txt` | Original preference values |
| `~/Library/Logs/MailAsyncAccountsFix.log` | Log |

## Manual equivalent

If you prefer to apply the preference changes by hand (quit Mail first):

```bash
defaults write com.apple.mail AutoFetch -bool NO
defaults write com.apple.mail DisableSynchronizationOnAppActivation -bool YES
```

To revert:

```bash
defaults delete com.apple.mail AutoFetch
defaults delete com.apple.mail DisableSynchronizationOnAppActivation
```

Checking a single account via AppleScript:

```applescript
tell application "Mail" to check for new mail for account "Account Name"
```

## Limitations

- **Mail launch.** At launch, Mail may still sync all accounts at once. The
  deadlock can still occur right after starting Mail.
- **Delay for other folders.** New mail in folders other than the inbox
  only shows up when that account's turn comes, so up to one round later.
- **iOS is not affected.** Mail on iPhone and iPad is not changed by this
  tool.
- **Updates.** A macOS or Mail update can change or remove the hidden
  preference.
- **This is a workaround, not a fix.** The real fix is to use fewer
  accounts, for example by consolidating addresses into a few mailboxes
  and sending from aliases. The underlying bug has been reported to Apple
  via Feedback Assistant.

## Diagnosing hangs

To capture what Mail is doing while it hangs (no admin password needed):

```bash
sample Mail 10 -file ~/Desktop/mail_hang.txt
```

Look for the header line `Dispatch Thread Soft Limit: 64 reached` and many
threads in `_synchronizeMailboxListDuringMailCheck`.

## License

MIT — no warranty. Use at your own risk.
