#!/bin/sh
# n-gpg.sh
#
# GPG decrypt filter for emil's shell pipe command.  Plaintext exists
# only in pipes and process memory (this script's, then emil's).
# Neither process locks its memory, so under memory pressure the OS
# could still page it out to swap; use encrypted swap if that matters.
#
# Usage in emil: mark the armored block, then
#
#   Alt-|  n-gpg.sh -d        plaintext appears in *Shell Output*
#
# Also works from the shell:  n-gpg.sh -d < vogon-poetry.asc | emil
#
# Using it inside emil:
#
# * The ciphertext must be ASCII-armored (gpg --armor).  emil only
#   loads valid UTF-8, so a binary .gpg file can't be opened.
#
# * Prefer Alt-| to C-u Alt-|.  C-u puts the plaintext into the
#   file-backed buffer in place of the ciphertext, so a reflexive
#   C-x C-s writes it to disk.  And emil replaces the region even when
#   the command fails -- here, with the error message.  C-_ undoes it.
#
# * Passphrase prompts need an emil that hands the terminal over while
#   a shell command runs (the pipe.c terminal-handover patch).  Older
#   emil reads the terminal itself during the command and eats the
#   keystrokes meant for pinentry.
#
# * emil discards stderr, so from inside emil failures are reported
#   on stdout, where they show up in *Shell Output*.
#
# Fail-closed: gpg decrypts as a stream and writes plaintext before it
# reaches the integrity check at the end of the message, so a corrupt
# or tampered file yields partial, garbled plaintext plus an error.
# This script holds the plaintext until gpg has finished and releases
# it only if gpg exits 0.  Note gpg also exits non-zero for a *valid*
# file signed by a key not in your keyring; import the signer's key.
#
# Requires: gpg

set -eu

# emil discards stderr; send ours where it can be seen.
[ -t 2 ] || exec 2>&1

if [ $# -ne 1 ] || [ "$1" != "-d" ]; then
    echo "usage: n-gpg.sh -d   (reads gpg data on stdin, writes plaintext to stdout)" >&2
    exit 1
fi

# If GPG_TTY isn't set, work it out.  The value must be the real
# device name (e.g. /dev/pts/3 or /dev/ttys003): pinentry is started
# by gpg-agent, a daemon with no controlling terminal, so the generic
# alias /dev/tty means nothing to it.  Try stderr first; under emil
# it's a pipe, so fall back to asking ps(1) for this process's
# controlling terminal.  With no terminal at all (cron, CI) GPG_TTY
# stays empty and gpg reports its own error.
if [ -z "${GPG_TTY-}" ]; then
    GPG_TTY=$(tty <&2 2>/dev/null) || GPG_TTY=
    if [ -z "$GPG_TTY" ]; then
        t=$(ps -o tty= -p $$ 2>/dev/null) || t=
        t=$(printf '%s' "$t" | tr -d ' ')
        case $t in
            '' | '?' | '??' | -) ;;
            /*) [ -c "$t" ] && GPG_TTY=$t ;;
            *) [ -c "/dev/$t" ] && GPG_TTY=/dev/$t ;;
        esac
    fi
fi
export GPG_TTY

# Run gpg with its plaintext going to $p and its messages to $err.
# The inner subshell releases the plaintext on fd 4 (our real stdout)
# only if gpg succeeded.  The trailing "x" sentinel stops $(...)
# stripping trailing newlines from the plaintext.
exec 4>&1
if err=$(
    {
        p=$(gpg --quiet --decrypt \
                2>&3 3>&- 4>&- && printf x) || exit
        printf '%s' "${p%x}" >&4
    } 3>&1
); then
    # gpg's notes on success (e.g. signature details) go to the
    # terminal if there is one, never into the plaintext.
    if [ -t 2 ] && [ -n "$err" ]; then
        printf '%s\n' "$err" >&2
    fi
    exit 0
else
    rc=$?
fi

# Failure.  Report on the terminal if we have one, else on stdout so
# emil shows it in *Shell Output*.
[ -t 2 ] && exec 1>&2
printf 'n-gpg.sh: gpg failed (exit %s); no plaintext released\n' "$rc"
[ -n "$err" ] && printf '%s\n' "$err"
exit "$rc"
