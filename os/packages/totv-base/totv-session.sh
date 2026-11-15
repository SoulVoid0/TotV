# TotV session hooks (/etc/profile.d/totv-session.sh, from totv-base).
#
# On a login shell on the first virtual console (where the installer's
# autologin lands), every *.sh in /usr/lib/totv/session.d and
# /etc/totv/session.d is sourced in name order; a file in /etc replaces the
# one of the same name in /usr/lib, and an empty or /dev/null file in /etc
# disables it. A hook may `exec` a session (a desktop, a game), which then
# replaces the login shell. Set TOTV_NO_SESSION=1 to skip the hooks.
if [ -z "${TOTV_SESSION_DONE:-}" ] && [ -z "${TOTV_NO_SESSION:-}" ] \
   && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ]; then
    export TOTV_SESSION_DONE=1
    for _totv_hook in $( { ls /usr/lib/totv/session.d/*.sh /etc/totv/session.d/*.sh 2>/dev/null || true; } \
                          | sed 's|.*/||' | sort -u); do
        if [ -e "/etc/totv/session.d/$_totv_hook" ]; then
            _totv_file="/etc/totv/session.d/$_totv_hook"
        else
            _totv_file="/usr/lib/totv/session.d/$_totv_hook"
        fi
        [ -s "$_totv_file" ] && . "$_totv_file"
    done
    unset _totv_hook _totv_file
fi
