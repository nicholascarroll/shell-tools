#!/bin/sh
# n-gpg.sh -- symmetric gpg encrypt/decrypt filter for emil's Alt-| pipe.
# Reads stdin, writes stdout. Plaintext lives only in pipes and memory, so
# use encrypted swap if paging is a concern. Requires: gpg.
#
# emil notes: mark a region and pipe it with Alt-| (not C-u Alt-|, which can
# leave plaintext in the file-backed buffer). Text must be ASCII-armored.
# Passphrase prompts need an emil that hands the terminal to the command
# while it runs. On failure nothing is written, so a bad run won't clobber
# the region -- gpg streams plaintext before its final integrity check, so
# we hold gpg's output and release it only on exit 0.

set -eu

# emil discards stderr; when we're not on a terminal, fold it into stdout so
# messages still reach *Shell Output*.
[ -t 2 ] || exec 2>&1

usage() {
    cat >&2 <<'EOF'
usage: n-gpg.sh MODE     reads stdin, writes stdout

  -e     encrypt   text in, ASCII-armored ciphertext out (prompts for a passphrase)
  -eb    encrypt in Beorg's headerless format, for pasting back into Beorg (-be too)
  -d     decrypt   OpenPGP message in, text out
  -bd    decrypt a Beorg message, repairing the header it leaves out (-db too)

In emil: mark a region, then  Alt-| n-gpg.sh -d
EOF
    exit "${1:-1}"
}

mode=; beorg=0
case ${1-} in
    -e)          mode=encrypt ;;
    -eb | -be)   mode=encrypt; beorg=1 ;;
    -d)          mode=decrypt ;;
    -bd | -db)   mode=decrypt; beorg=1 ;;
    -h | --help) usage 0 ;;
    *)           usage ;;
esac
[ $# -eq 1 ] || usage

# pinentry is run by gpg-agent, which has no controlling terminal, so GPG_TTY
# must name the real device. Take it from stderr, or from ps if stderr is a
# pipe (as under emil); leave it empty when there's no terminal at all.
if [ -z "${GPG_TTY-}" ]; then
    GPG_TTY=$(tty <&2 2>/dev/null) || GPG_TTY=
    if [ -z "$GPG_TTY" ]; then
        t=$(ps -o tty= -p $$ 2>/dev/null) || t=
        t=$(printf '%s' "$t" | tr -d ' ')
        case $t in
            '' | '?' | '??' | -) ;;
            /*) [ -c "$t" ] && GPG_TTY=$t ;;
            *)  [ -c "/dev/$t" ] && GPG_TTY=/dev/$t ;;
        esac
    fi
fi
export GPG_TTY

# -eb: Beorg reads only its own headerless format, so mimic it. Encrypt with a
# simple SHA-256 S2K and AES256, drop the 6-byte session-key packet gpg adds
# (leaving the bare encrypted-data packet Beorg expects), and re-armor via
# enarmor with the banner relabelled MESSAGE. The temp file holds ciphertext
# only; the plaintext never leaves stdin and memory.
if [ "$mode" = encrypt ] && [ "$beorg" -eq 1 ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/n-gpg.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT INT TERM HUP
    if err=$(gpg --quiet --symmetric --s2k-mode 0 --s2k-digest-algo SHA256 \
                 --cipher-algo AES256 2>&1 >"$tmp"); then
        tail -c +7 "$tmp" | gpg --enarmor 2>/dev/null \
            | sed -e 's/PGP ARMORED FILE/PGP MESSAGE/' -e '/^Comment:/d' -e '/^Version:/d'
        if [ -t 2 ] && [ -n "$err" ]; then printf '%s\n' "$err" >&2; fi
        exit 0
    else
        rc=$?
        [ -t 2 ] && exec 1>&2
        printf 'n-gpg.sh: gpg failed (exit %s); no ciphertext written\n' "$rc"
        [ -n "$err" ] && printf '%s\n' "$err"
        exit "$rc"
    fi
fi

# -bd: Beorg writes a headerless message, so gpg mis-guesses and reports
# "manipulated". Clean up common export damage (a UTF-8 BOM or junk before
# -----BEGIN, CRLF endings; NULs from a UTF-16 file are dropped by $(...)),
# bail out clearly if no readable block survives, and let the decrypt below
# prepend the missing header.
beorg_clean=
if [ "$mode" = decrypt ] && [ "$beorg" -eq 1 ]; then
    beorg_clean=$(cat | awk '
        /-----BEGIN PGP/ { p = 1; sub(/^.*-----BEGIN PGP/, "-----BEGIN PGP") }
        p                { sub(/\r$/, ""); print }
        /-----END PGP/   { exit }
    ')
    if ! printf '%s\n' "$beorg_clean" | grep -q -- '-----BEGIN PGP'; then
        [ -t 2 ] && exec 1>&2
        echo "n-gpg.sh: no ASCII-armored PGP block on input." >&2
        echo "  It must start with -----BEGIN PGP MESSAGE-----." >&2
        echo "  A binary .gpg or UTF-16 file won't work; re-export as armored text." >&2
        exit 1
    fi
    if [ "$(printf '%s\n' "$beorg_clean" | gpg --dearmor 2>/dev/null | wc -c)" -le 0 ]; then
        [ -t 2 ] && exec 1>&2
        echo "n-gpg.sh: the PGP block is present but unreadable (truncated or bad checksum)." >&2
        exit 1
    fi
fi

# Run gpg with its output captured in $p and its messages in $err, releasing
# the output on fd 4 (the real stdout) only if gpg exited 0. The trailing "x"
# keeps $(...) from stripping trailing newlines. The 6 prepended bytes for
# -bd are the tag-3 packet gpg needs: v4, AES256 (9), simple S2K (0), SHA-256 (8).
exec 4>&1
if err=$(
    {
        case $mode in
        encrypt)
            p=$(gpg --quiet --symmetric --armor 2>&3 3>&- 4>&- && printf x) || exit
            ;;
        decrypt)
            if [ "$beorg" -eq 1 ]; then
                p=$( { printf '\303\004\004\011\000\010'
                       printf '%s\n' "$beorg_clean" | gpg --dearmor 2>&3 3>&- 4>&- ; } \
                     | gpg --quiet --decrypt 2>&3 3>&- 4>&- && printf x) || exit
            else
                p=$(gpg --quiet --decrypt 2>&3 3>&- 4>&- && printf x) || exit
            fi
            ;;
        esac
        printf '%s' "${p%x}" >&4
    } 3>&1
); then
    if [ -t 2 ] && [ -n "$err" ]; then
        printf '%s\n' "$err" >&2
    fi
    exit 0
else
    rc=$?
fi

# Failure: report on the terminal, else on stdout so emil shows it.
[ -t 2 ] && exec 1>&2
if [ "$mode" = encrypt ]; then
    printf 'n-gpg.sh: gpg failed (exit %s); no ciphertext written\n' "$rc"
else
    printf 'n-gpg.sh: gpg failed (exit %s); no plaintext released\n' "$rc"
fi
[ -n "$err" ] && printf '%s\n' "$err"
exit "$rc"