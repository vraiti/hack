#!/usr/bin/env bash
set -euo pipefail

echo "Configuring idle SSH auto-stop..."

sudo tee /usr/local/bin/ssh-session-hook.sh > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
IDLE_TIMER_PID="/tmp/.idle-shutdown.pid"

case "$PAM_TYPE" in
    open_session)
        if [[ -f "$IDLE_TIMER_PID" ]]; then
            kill "$(cat "$IDLE_TIMER_PID")" 2>/dev/null
            rm -f "$IDLE_TIMER_PID"
        fi
        ;;
    close_session)
        if [[ $(who | wc -l) -eq 0 ]]; then
            (sleep 900 && /usr/sbin/shutdown -h now) &
            echo $! > "$IDLE_TIMER_PID"
            disown
        fi
        ;;
esac
SCRIPT
sudo chmod +x /usr/local/bin/ssh-session-hook.sh

if ! sudo grep -q 'ssh-session-hook' /etc/pam.d/sshd; then
    echo "session optional pam_exec.so /usr/local/bin/ssh-session-hook.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null
fi

echo "Done."
