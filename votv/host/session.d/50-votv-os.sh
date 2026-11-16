# shellcheck shell=sh
# TotV OS: the tty1 autologin starts the Voices of the Void session.
# Sourced by /etc/profile.d/totv-session.sh on tty1; override with /etc/totv/session.d/50-votv-os.sh.
if command -v votv-os-session >/dev/null 2>&1 && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    exec votv-os-session
fi
