#!/bin/sh
# n-thai-zw.sh: insert U+200B ZERO WIDTH SPACE between Thai words
#
# Usage:
#   n-thai-zw.sh [-f] [FILE]            annotated text to stdout
#   n-thai-zw.sh [-f] [-b] -i FILE      rewrite FILE in place
#
#   -f   force: remove existing U+200B and annotate everything again
#   -i   --in-place: replace FILE atomically
#   -b   with -i, keep the original as FILE.bak
#
# In emil: mark a region, Ctrl-u Alt-| n-thai-zw.sh
#
# The text looks unchanged; word motion, word wrap and tag lookup
# (M-.) then see Thai word boundaries.  The LLM (via n-gpt.sh) only
# proposes where the boundaries go.  Its output is accepted only if
# removing the boundaries gives back the input byte for byte, so the
# text itself can never be altered.  A chunk that fails that check is
# passed through unannotated and the exit status is 1.
#
# Lines that already contain U+200B are passed through untouched, so
# running this again after a partial failure annotates only what is
# missing.  -f re-annotates everything.
#
# Filter mode never loses text: on any failure the input is written
# back out unchanged (emil's replace-region would otherwise replace
# the region with nothing).
#
# Environment:
#   NGPT            LLM filter command (default n-gpt.sh)
#   THAI_CHUNK      bytes of text per LLM call (default 3000)
#   THAI_JOBS       concurrent LLM calls (default 4)
#   AWK             awk to use; must treat text as bytes under LC_ALL=C
#
# Requires: awk.  If FILE is open in emil, emil notices the change and
# asks before saving over it.

LC_ALL=C
export LC_ALL
NGPT=${NGPT:-n-gpt.sh}
CHUNK=${THAI_CHUNK:-3000}
JOBS=${THAI_JOBS:-4}
me='n-thai-zw.sh'

usage() {
	sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

# ---- options -----------------------------------------------------------
inplace='' force='' backup='' file=''
while [ $# -gt 0 ]; do
	case $1 in
	-i | --in-place) inplace=1 ;;
	-f | --force) force=1 ;;
	-b | --backup) backup=1 ;;
	-h | --help) usage ;;
	--) shift; break ;;
	-?*) echo "$me: unknown option $1" >&2; usage ;;
	*) break ;;
	esac
	shift
done
[ $# -le 1 ] || usage
file=${1:-}
[ -n "$inplace" ] && [ -z "$file" ] && usage
[ -n "$backup" ] && [ -z "$inplace" ] && usage

if [ -n "$file" ] && [ ! -r "$file" ]; then
	echo "$me: cannot read $file" >&2
	exit 1
fi
if [ -n "$inplace" ]; then
	if [ -h "$file" ] || [ ! -f "$file" ]; then
		echo "$me: $file: not a regular file; refusing -i" >&2
		exit 1
	fi
	[ -w "$file" ] || { echo "$me: $file is not writable" >&2; exit 1; }
fi

# ---- capture input; from here on, failures in filter mode pass it through
T=$(mktemp -d "${TMPDIR:-/tmp}/n-thai-zw.XXXXXX") || {
	echo "$me: mktemp failed" >&2
	[ -z "$inplace" ] && cat ${file:+"$file"}
	exit 1
}
jobs_running=
cleanup() {
	for p in $jobs_running; do kill "${p%%:*}" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [ -n "$file" ]; then
	cat "$file" >"$T/in" || exit 1
else
	cat >"$T/in"
fi

fail() {
	echo "$me: $*" >&2
	[ -z "$inplace" ] && cat "$T/in"
	exit 1
}

pick_awk() {
	for a in ${AWK:-} awk mawk gawk nawk original-awk; do
		command -v "$a" >/dev/null 2>&1 || continue
		n=$(printf '\340\270\201' | "$a" '{ print length($0) }' 2>/dev/null)
		[ "$n" = 3 ] && { AWK=$a; return 0; }
	done
	return 1
}
pick_awk || fail "no byte-oriented awk found (set AWK)"

# ---- shared Thai character functions (bytes, UTF-8) --------------------
# Thai is U+0E00..U+0E7F, i.e. E0 B8 80..E0 B9 BF.  E0 is only ever a
# lead byte, so searching for "\340\270" / "\340\271" at any offset
# finds exactly the Thai characters.  tk() maps one to its offset from
# U+0E00 (0..127).
THAI_LIB='
function thai_init() {
	ZW = "\342\200\213"; TH1 = "\340\270"; TH2 = "\340\271"
	T64 = "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217" \
	      "\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237" \
	      "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257" \
	      "\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277"
}
function tk(c) {
	return index(T64, substr(c, 3, 1)) - 1 + (substr(c, 2, 1) == "\271" ? 64 : 0)
}
function isthaiat(s, i,   c2) { c2 = substr(s, i, 2); return c2 == TH1 || c2 == TH2 }
function hasthai(s) { return index(s, TH1) > 0 || index(s, TH2) > 0 }
# combining marks: MAI HAN-AKAT, SARA I..PHINTHU, MAITAIKHU..YAMAKKAN
function iscomb(k) { return k == 49 || (k >= 52 && k <= 58) || (k >= 71 && k <= 78) }
function delall(s, t,   i, r) {
	r = ""
	while ((i = index(s, t)) > 0) { r = r substr(s, 1, i - 1); s = substr(s, i + length(t)) }
	return r s
}
'

# ---- split input into chunks -------------------------------------------
# Manifest lines: "id kind marker".  kind A = send to the LLM, P = pass
# through (already annotated, or no Thai).  marker is "|" when the chunk
# has no "|" of its own, else "z" (ask for U+200B directly).
# shellcheck disable=SC2016
"$AWK" -v DIR="$T" -v MAXB="$CHUNK" -v FORCE="$force" "$THAI_LIB"'
BEGIN { thai_init() }
function flush(   f) {
	if (n == 0) return
	id = sprintf("%05d", ++nc)
	f = DIR "/c." id
	printf "%s", buf > f
	close(f)
	print id, (kind == "A" && thai ? "A" : "P"), (pipe ? "z" : "|")
	n = 0; buf = ""; thai = 0; pipe = 0; bytes = 0
}
{
	line = $0
	if (FORCE) line = delall(line, ZW)
	k = index(line, ZW) ? "P" : "A"
	if (n && (k != kind || (k == "A" && bytes + length(line) + 1 > MAXB))) flush()
	kind = k; buf = buf line "\n"; n++; bytes += length(line) + 1
	if (hasthai(line)) thai = 1
	if (index(line, "|")) pipe = 1
}
END { flush() }
' "$T/in" >"$T/manifest" || fail "splitting input failed"

if ! grep -q ' A ' "$T/manifest"; then
	# Nothing to annotate: no Thai, or already annotated.
	[ -z "$inplace" ] && cat "$T/in"
	exit 0
fi
command -v "$NGPT" >/dev/null 2>&1 || fail "LLM command not found: $NGPT"

instruction() {
	if [ "$1" = "|" ]; then
		what='the character | (vertical bar)'
	else
		what='the character U+200B ZERO WIDTH SPACE'
	fi
	printf '%s' "Segment the Thai text into words by inserting $what between adjacent Thai words. Change nothing else: every other character, space, punctuation mark and line break must be output exactly as given, in the same order. Do not add spaces. Do not translate, romanize, correct spelling, or comment. Segment at the level of words a learner would look up in a dictionary, keeping established compounds such as โรงเรียน or เครื่องบิน together."
}

# ---- call the LLM, at most $JOBS at a time -------------------------------
reap_one() {
	set -- $jobs_running
	first=$1
	shift
	jobs_running=$*
	wait "${first%%:*}"
	echo $? >"$T/s.${first#*:}"
}
njobs=0
while read -r id kind mark; do
	[ "$kind" = A ] || continue
	"$NGPT" "$(instruction "$mark")" <"$T/c.$id" >"$T/r.$id" 2>"$T/e.$id" &
	jobs_running="$jobs_running $!:$id"
	njobs=$((njobs + 1))
	[ "$njobs" -ge "$JOBS" ] && { reap_one; njobs=$((njobs - 1)); }
done <"$T/manifest"
while [ -n "$(echo $jobs_running)" ]; do reap_one; done

# ---- verify and assemble -------------------------------------------------
# Accept an LLM chunk only if deleting the markers gives back the
# original lines exactly.  The LLM never sees leading or trailing blank
# lines faithfully (n-gpt.sh reads input with $(cat)), so those are
# compared around, and restored from the original.  Markers survive only
# between two Thai characters, never inside a character cluster: not
# after a preposed vowel, not before a combining mark, MAI YAMOK or
# PAIYANNOI.
VERIFY="$THAI_LIB"'
BEGIN { thai_init() }
FNR == NR { o[++no] = $0; next }
{ l[++nl] = $0 }
function strip(s) { s = delall(s, ZW); if (MARK == "|") s = delall(s, "|"); return s }
function clean(s,   out, i, L, c, k, pk, pend) {
	if (MARK == "|") gsub(/\|/, ZW, s)
	out = ""; pend = 0; pk = -1; L = length(s); i = 1
	while (i <= L) {
		if (substr(s, i, 3) == ZW) { pend = 1; i += 3; continue }
		if (isthaiat(s, i)) { c = substr(s, i, 3); k = tk(c); i += 3 }
		else { c = substr(s, i, 1); k = -1; i++ }
		if (pend && pk >= 0 && !(pk >= 64 && pk <= 68) && \
		    k >= 0 && !iscomb(k) && k != 70 && k != 47)
			out = out ZW
		pend = 0; out = out c; pk = k
	}
	return out
}
END {
	lf = 1; ll = nl
	if (ll >= lf && substr(l[lf], 1, 3) == "```" && substr(o[1], 1, 3) != "```") lf++
	if (ll >= lf && l[ll] ~ /^```[ \t]*$/ && o[no] !~ /^```/) ll--
	for (i = 1; i <= nl; i++) sub(/\r$/, "", l[i])
	of = 1; ol = no
	while (of <= ol && o[of] == "") of++
	while (ol >= of && o[ol] == "") ol--
	while (lf <= ll && l[lf] == "") lf++
	while (ll >= lf && l[ll] == "") ll--
	if (ol - of != ll - lf) exit 1
	for (i = 0; of + i <= ol; i++)
		if (strip(l[lf + i]) != o[of + i]) exit 1
	for (i = 1; i < of; i++) print ""
	for (i = 0; of + i <= ol; i++) print clean(l[lf + i])
	for (i = ol + 1; i <= no; i++) print ""
}'

total=0 failed=0 firsterr=
: >"$T/out"
while read -r id kind mark; do
	if [ "$kind" = A ]; then
		total=$((total + 1))
		if [ "$(cat "$T/s.$id" 2>/dev/null)" = 0 ] &&
			"$AWK" -v MARK="$mark" "$VERIFY" "$T/c.$id" "$T/r.$id" >"$T/v.$id"
		then
			cat "$T/v.$id" >>"$T/out"
			continue
		fi
		failed=$((failed + 1))
		if [ -z "$firsterr" ]; then
			firsterr=$(head -n 1 "$T/e.$id" 2>/dev/null)
			[ -n "$firsterr" ] || firsterr="LLM output did not reproduce the text"
		fi
	fi
	cat "$T/c.$id" >>"$T/out"
done <"$T/manifest"

# Chunks always end in a newline; restore a missing final one.
if [ -s "$T/in" ] && [ "$(tail -c 1 "$T/in" | od -An -c | tr -d ' ')" != '\n' ]; then
	"$AWK" 'NR > 1 { printf "\n" } { printf "%s", $0 }' "$T/out" >"$T/out2" &&
		mv "$T/out2" "$T/out"
fi

# ---- final invariant: only U+200B may differ between input and output ----
# Whatever went wrong above, never hand back altered or truncated text.
"$AWK" "$THAI_LIB"'BEGIN { thai_init() } { print delall($0, ZW) }' "$T/in" >"$T/in.bare" &&
	"$AWK" "$THAI_LIB"'BEGIN { thai_init() } { print delall($0, ZW) }' "$T/out" >"$T/out.bare" &&
	cmp -s "$T/in.bare" "$T/out.bare" ||
	fail "internal error: output would differ from input beyond U+200B"

# ---- deliver ---------------------------------------------------------------
if [ -z "$inplace" ]; then
	cat "$T/out"
	if [ "$failed" -gt 0 ]; then
		echo "$me: $failed of $total chunks left unannotated ($firsterr)" >&2
		exit 1
	fi
	exit 0
fi

if [ "$failed" -gt 0 ]; then
	echo "$me: $failed of $total chunks failed ($firsterr); $file not modified" >&2
	exit 1
fi
if ! "$AWK" "$THAI_LIB"'BEGIN { thai_init() } hasthai($0) { f = 1; exit } END { exit !f }' "$T/out"; then
	echo "$me: output empty or without Thai; $file not modified" >&2
	exit 1
fi
if cmp -s "$T/in" "$T/out"; then
	exit 0
fi
# Replace FILE, unless it changed while the LLM was working.
if ! cmp -s "$file" "$T/in"; then
	echo "$me: $file changed during annotation; not replaced" >&2
	exit 1
fi
if [ -n "$backup" ]; then
	cp -p "$file" "$file.bak" || exit 1
fi
tmp="$(dirname "$file")/.$(basename "$file").zw.$$"
# cp -p then overwrite, so the replacement keeps FILE's mode.
if cp -p "$file" "$tmp" && cat "$T/out" >"$tmp" && mv -f "$tmp" "$file"; then
	exit 0
fi
rm -f "$tmp"
echo "$me: could not replace $file" >&2
exit 1
