#!/bin/bash
# =====================================================================
#  MailAsyncAccountsFix.command
#
#  Goal: stop Apple Mail from fetching all accounts at the same time
#  (prevents the "64 dispatch threads blocked" deadlock seen with
#  many IMAP accounts).
#
#  Install does:
#   1. Mail: "Check for new messages" -> Manually   (defaults: AutoFetch = NO)
#   2. Hidden setting: DisableSynchronizationOnAppActivation = YES
#      (no fetch of all accounts when Mail comes to the foreground)
#   3. Background service (LaunchAgent): every X minutes it checks the
#      accounts ONE AFTER ANOTHER, with a pause in between.
#  IMAP push (IDLE) for the inbox stays active.
#
#  Uninstall restores the previous settings.
#  No e-mails are modified.
# =====================================================================
set -u

LABEL="com.github.arturfromtheblock.mail-async-accounts-fix"
APPDIR="$HOME/Library/Application Support/MailAsyncAccountsFix"
WORKER="$APPDIR/fetch-staggered.sh"
BACKUP="$APPDIR/backup.txt"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/MailAsyncAccountsFix.log"
GUI="gui/$(id -u)"

# --- Staggered fetch settings -----------------------------------------
INTERVAL_MIN=10      # start a new round every N minutes
PAUSE_SEC=10         # pause between two accounts

pause_exit() { echo; read -r -p "Press Enter to close ..." _; exit "${1:-0}"; }

mail_running() { pgrep -x Mail >/dev/null 2>&1; }

start_mail() {
  mail_running && return 0
  open -a Mail
  for i in $(seq 1 30); do sleep 1; mail_running && { sleep 3; return 0; }; done
  return 1
}

quit_mail() {
  mail_running || return 0
  osascript -e 'with timeout of 20 seconds' -e 'tell application "Mail" to quit' -e 'end timeout' >/dev/null 2>&1
  for i in $(seq 1 20); do mail_running || return 0; sleep 1; done
  echo "Mail does not respond to Quit."
  read -r -p "Force quit Mail now? [Y/n] " a
  if [[ ! "$a" =~ ^[nN] ]]; then pkill -9 -x Mail; sleep 2; fi
  ! mail_running
}

check_access() {
  if ! ls "$HOME/Library/Mail" >/dev/null 2>&1; then
    echo "Terminal needs 'Full Disk Access' once."
    echo "  -> Enable 'Terminal' in the window that opens now,"
    echo "     quit Terminal completely (Cmd+Q) and run this script again."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null
    pause_exit 1
  fi
}

write_worker() {
  mkdir -p "$APPDIR" "$(dirname "$LOG")"
  cat > "$WORKER" <<WEOF
#!/bin/bash
# Staggered Mail fetch - started by the LaunchAgent.
PAUSE_SEC=$PAUSE_SEC
LOG="$LOG"
LOCK="$APPDIR/.lock"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# Only work while Mail is running (never launches Mail itself)
pgrep -x Mail >/dev/null 2>&1 || exit 0
# Never run two rounds at once
mkdir "\$LOCK" 2>/dev/null || { echo "\$(ts) Previous round still running - skipped" >> "\$LOG"; exit 0; }
trap 'rmdir "\$LOCK" 2>/dev/null' EXIT

OK=1
for TRY in 1 2 3; do
NAMES=\$(osascript 2>&1 <<'AS'
with timeout of 60 seconds
tell application "Mail"
  set out to ""
  repeat with a in (every account whose enabled is true)
    set out to out & (name of a) & linefeed
  end repeat
end tell
end timeout
return out
AS
)
  if [ \$? -eq 0 ]; then OK=0; break; fi
  sleep 20
done
if [ \$OK -ne 0 ]; then
  echo "\$(ts) ERROR reading accounts: \$NAMES" >> "\$LOG"
  echo "\$(ts) -> If needed, allow 'bash'/'osascript' to control Mail in System Settings > Privacy & Security > Automation." >> "\$LOG"
  exit 1
fi

N=0
echo "\$(ts) Round started" >> "\$LOG"
while IFS= read -r NAME; do
  [ -z "\$NAME" ] && continue
  pgrep -x Mail >/dev/null 2>&1 || { echo "\$(ts) Mail was quit - round aborted" >> "\$LOG"; exit 0; }
  if osascript -e 'on run argv' -e 'with timeout of 30 seconds' \
       -e 'tell application "Mail" to check for new mail for account (item 1 of argv)' \
       -e 'end timeout' -e 'end run' "\$NAME" >/dev/null 2>>"\$LOG"; then
    N=\$((N+1))
  else
    echo "\$(ts) Fetch failed: \$NAME" >> "\$LOG"
  fi
  sleep "\$PAUSE_SEC"
done <<< "\$NAMES"
echo "\$(ts) Round finished (\$N accounts checked)" >> "\$LOG"

# Keep the log small
tail -n 2000 "\$LOG" > "\$LOG.tmp" 2>/dev/null && mv "\$LOG.tmp" "\$LOG"
WEOF
  chmod +x "$WORKER"
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$WORKER</string></array>
  <key>StartInterval</key><integer>$((INTERVAL_MIN*60))</integer>
  <key>RunAtLoad</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PEOF
}

# Checks whether Mail answers AppleScript (with retries - Mail starts slowly with many accounts)
applescript_test() {
  for i in 1 2 3 4 5 6; do
    R=$(osascript -e 'with timeout of 30 seconds' -e 'tell application "Mail" to count of (every account whose enabled is true)' -e 'end timeout' 2>&1)
    if [[ "$R" =~ ^[0-9]+$ ]]; then
      echo "     OK - Mail responds, $R enabled accounts."
      return 0
    fi
    if [[ "$R" == *"-1743"* ]]; then
      echo "     Not authorized (-1743): System Settings > Privacy & Security > Automation"
      echo "     -> under 'Terminal', switch on 'Mail'."
      return 1
    fi
    echo "     Mail not ready yet ($R) - retrying in 10 s ..."
    sleep 10
  done
  echo "     Mail does not respond to AppleScript. The service will retry every round."
  return 1
}

install() {
  check_access
  if [ -f "$BACKUP" ]; then
    echo "MailAsyncAccountsFix is already installed (see option 3: Status)."
    pause_exit 0
  fi

  echo "1/5  Quitting Mail ..."
  quit_mail || { echo "Mail is still running - aborted. Please quit Mail and try again."; pause_exit 1; }

  echo "2/5  Backing up current settings ..."
  OLD_AUTO=$(defaults read com.apple.mail AutoFetch 2>/dev/null || echo "unset")
  OLD_DSA=$(defaults read com.apple.mail DisableSynchronizationOnAppActivation 2>/dev/null || echo "unset")
  mkdir -p "$APPDIR"
  printf "AutoFetch=%s\nDisableSynchronizationOnAppActivation=%s\n" "$OLD_AUTO" "$OLD_DSA" > "$BACKUP"
  echo "     Saved: AutoFetch=$OLD_AUTO, DisableSynchronizationOnAppActivation=$OLD_DSA"

  echo "3/5  Fetch set to 'Manually' + no fetch on app activation ..."
  defaults write com.apple.mail AutoFetch -bool NO
  defaults write com.apple.mail DisableSynchronizationOnAppActivation -bool YES
  A=$(defaults read com.apple.mail AutoFetch 2>/dev/null)
  D=$(defaults read com.apple.mail DisableSynchronizationOnAppActivation 2>/dev/null)
  echo "     AutoFetch=$A (expected 0)   DisableSynchronizationOnAppActivation=$D (expected 1)"
  if [ "$A" != "0" ] || [ "$D" != "1" ]; then
    echo "     WARNING: settings were not saved as expected."
  fi

  echo "4/5  Setting up background service (every $INTERVAL_MIN min, $PAUSE_SEC s pause per account) ..."
  write_worker
  write_plist
  launchctl bootout "$GUI/$LABEL" 2>/dev/null
  launchctl bootstrap "$GUI" "$PLIST" && echo "     Service active." || echo "     WARNING: service could not be started."

  echo "5/5  Starting Mail and testing AppleScript access ..."
  start_mail
  applescript_test
  echo "$(date '+%Y-%m-%d %H:%M:%S') Installed" >> "$LOG"
  launchctl kickstart "$GUI/$LABEL" 2>/dev/null
  echo
  echo "Done. Please check Mail > Settings > General:"
  echo "  'Check for new messages' should now be set to 'Manually'."
  echo "If macOS asks whether 'bash' or 'osascript' may control Mail: ALLOW."
  pause_exit 0
}

uninstall() {
  echo "Stopping and removing the service ..."
  launchctl bootout "$GUI/$LABEL" 2>/dev/null
  rm -f "$PLIST"

  OLD_AUTO=unset; OLD_DSA=unset
  if [ -f "$BACKUP" ]; then
    OLD_AUTO=$(grep '^AutoFetch=' "$BACKUP" | cut -d= -f2)
    OLD_DSA=$(grep '^DisableSynchronizationOnAppActivation=' "$BACKUP" | cut -d= -f2)
  fi

  echo "Quitting Mail and restoring settings ..."
  quit_mail
  for KEY in AutoFetch DisableSynchronizationOnAppActivation; do
    [ "$KEY" = "AutoFetch" ] && V="$OLD_AUTO" || V="$OLD_DSA"
    if [ -z "$V" ] || [ "$V" = "unset" ]; then
      defaults delete com.apple.mail "$KEY" 2>/dev/null
      echo "  $KEY: removed (default)"
    else
      [ "$V" = "1" ] && B=YES || B=NO
      defaults write com.apple.mail "$KEY" -bool "$B"
      echo "  $KEY: $B"
    fi
  done

  rm -rf "$APPDIR"
  echo "$(date '+%Y-%m-%d %H:%M:%S') Uninstalled" >> "$LOG"
  start_mail
  echo
  echo "Everything restored. (Log is kept: $LOG)"
  pause_exit 0
}

status() {
  echo "--- Service ---"
  if launchctl print "$GUI/$LABEL" >/dev/null 2>&1; then
    echo "active  (every $INTERVAL_MIN min)"
  else
    echo "not installed"
  fi
  echo
  echo "--- Settings ---"
  echo "DisableSynchronizationOnAppActivation = $(defaults read com.apple.mail DisableSynchronizationOnAppActivation 2>/dev/null || echo 'not set')"
  echo "AutoFetch = $(defaults read com.apple.mail AutoFetch 2>/dev/null || echo 'not set (automatic)')"
  mail_running && applescript_test
  [ -f "$BACKUP" ] && { echo "Saved original state:"; sed 's/^/  /' "$BACKUP"; }
  echo
  echo "--- Latest log entries ---"
  tail -n 15 "$LOG" 2>/dev/null || echo "(empty)"
  echo
  echo "--- Did Mail fetch ALL accounts automatically in the last 2 hours? ---"
  HITS=$(log show --last 2h --style compact \
    --predicate 'process == "Mail" AND (eventMessage CONTAINS "performing automatic fetch" OR eventMessage CONTAINS "fetch for all accounts")' 2>/dev/null \
    | grep -v '^Timestamp' | grep -c .)
  if [ "${HITS:-0}" -eq 0 ]; then
    echo "No - good. Mail did not start a fetch of all accounts."
  else
    echo "Yes, $HITS times:"
    log show --last 2h --style compact \
      --predicate 'process == "Mail" AND (eventMessage CONTAINS "performing automatic fetch" OR eventMessage CONTAINS "fetch for all accounts")' 2>/dev/null \
      | grep -v '^Timestamp' | tail -n 5 | cut -c1-200
  fi
  pause_exit 0
}

clear
echo "=============================================="
echo "   MailAsyncAccountsFix"
echo "   Staggered account fetching for Apple Mail"
echo "=============================================="
echo
echo "  1) Install"
echo "  2) Uninstall (restore everything)"
echo "  3) Status / check"
echo "  4) Cancel"
echo
read -r -p "Choice [1-4]: " CHOICE
echo
case "$CHOICE" in
  1) install ;;
  2) uninstall ;;
  3) status ;;
  *) exit 0 ;;
esac
