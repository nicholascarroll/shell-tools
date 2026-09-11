#!/bin/sh
# n-thai-vocab.sh: add the unknown Thai words in a text to your dictionary
#
# Usage:
#   n-thai-vocab.sh [-s SOURCE] [-L] [FILE]   acquire new words
#   n-thai-vocab.sh -n [FILE]                 list unknown words only
#   n-thai-vocab.sh -R                        check, sort, dedupe, re-index
#
#   -s   source name recorded in the acquisition log
#   -L   do not write the acquisition log
#
# In emil: mark a region of annotated text, Alt-| n-thai-vocab.sh -s "ch 3"
#
# Reads Thai text whose words are separated by U+200B (see n-thai-zw.sh)
# on stdin or from FILE.  Words not yet in the dictionary are sent to the
# LLM (via n-gpt.sh) in batches.  Entries that pass validation are
# added; the dictionary is re-sorted and the tags file rebuilt, so M-.
# on a Thai word in emil jumps to its entry.  The report (new entries,
# then a summary) goes to stdout, since emil discards stderr.
#
# Files, in THAI_DICT_DIR (default ~/thai):
#   dict.tsv       headword TAB romanization TAB definition, sorted
#   tags           headword -> line in dict.tsv, for emil's M-.
#   acquired.log   date TAB headword TAB romanization TAB definition TAB source
# emil finds "tags" by searching upward from its working directory, so
# keep study texts below THAI_DICT_DIR, or point THAI_TAGS elsewhere.
#
# dict.tsv is replaced atomically and re-read just before writing.  If
# it is open in emil, emil notices the change and asks before saving
# over it.  Don't run two acquisitions at the same moment: there is no
# lock, so one could overwrite the other's additions.
#
# Environment:
#   THAI_DICT_DIR     default ~/thai
#   THAI_DICT         default $THAI_DICT_DIR/dict.tsv
#   THAI_TAGS         default $THAI_DICT_DIR/tags
#   THAI_LOG          default $THAI_DICT_DIR/acquired.log
#   NGPT              LLM filter command (default n-gpt.sh)
#   THAI_BATCH        words per LLM call (default 80)
#   THAI_JOBS         concurrent LLM calls (default 4)
#   THAI_CONTEXT_MAX  send the passage for context if at most this many
#                     bytes (default 6000; 0 never sends it)
#   THAI_MAXLEN       longer runs, in characters, are taken to be
#                     unsegmented and skipped (default 24)
#   AWK               awk to use; must treat text as bytes under LC_ALL=C
#
# Requires: awk, sort; iconv if present.

LC_ALL=C
export LC_ALL
me='n-thai-vocab.sh'
TAB=$(printf '\t')
DICT_DIR=${THAI_DICT_DIR:-$HOME/thai}
DICT=${THAI_DICT:-$DICT_DIR/dict.tsv}
TAGS=${THAI_TAGS:-$DICT_DIR/tags}
LOG=${THAI_LOG:-$DICT_DIR/acquired.log}
NGPT=${NGPT:-n-gpt.sh}
BATCH=${THAI_BATCH:-80}
JOBS=${THAI_JOBS:-4}
CONTEXT_MAX=${THAI_CONTEXT_MAX:-6000}
MAXLEN=${THAI_MAXLEN:-24}

say() { printf '%s\n' "$*"; }
die() { say "$me: $*"; exit 1; }
usage() {
	sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

pick_awk() {
	for a in ${AWK:-} awk mawk gawk nawk original-awk; do
		command -v "$a" >/dev/null 2>&1 || continue
		n=$(printf '\340\270\201' | "$a" '{ print length($0) }' 2>/dev/null)
		[ "$n" = 3 ] && { AWK=$a; return 0; }
	done
	die "no byte-oriented awk found (set AWK)"
}

# ---- Thai character functions (bytes, UTF-8) -----------------------------
# Thai is U+0E00..U+0E7F = E0 B8 80..E0 B9 BF; E0 is only ever a lead
# byte, so "\340\270" / "\340\271" at any offset starts a Thai character.
# tk() gives its offset from U+0E00 (0..127).
#
# A word is a run of Thai letters, vowels, marks and PAIYANNOI (ฯ);
# U+200B, digits, MAI YAMOK (ๆ), other Thai signs and all non-Thai text
# end it.  emil's tag lookup (ctags.c, isThaiWordCP) uses the same rule.
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
function istok(k) { return (k >= 1 && k <= 58) || (k >= 64 && k <= 69) || (k >= 71 && k <= 78) }
function iscons(k) { return k >= 1 && k <= 46 }
function ccc(k) {
	if (k == 56 || k == 57) return 103   # SARA U, SARA UU
	if (k == 58) return 9                # PHINTHU
	if (k >= 72 && k <= 75) return 107   # tone marks
	return 0
}
function delall(s, t,   i, r) {
	r = ""
	while ((i = index(s, t)) > 0) { r = r substr(s, 1, i - 1); s = substr(s, i + length(t)) }
	return r s
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# 1 if w is entirely Thai word characters and contains a consonant
function isword(w,   i, n, c, k, cons) {
	n = length(w)
	if (n == 0 || n % 3) return 0
	for (i = 1; i <= n; i += 3) {
		c = substr(w, i, 3)
		if (!isthaiat(c, 1)) return 0
		k = tk(c)
		if (!istok(k)) return 0
		if (iscons(k)) cons = 1
	}
	return cons
}
# NFC for a Thai word.  Thai has no canonical compositions, so NFC is
# the canonical ordering of adjacent marks: SARA U/UU before tone marks.
function nfc(w,   n, i, j, a, c, ck) {
	n = length(w) / 3
	for (i = 1; i <= n; i++) a[i] = substr(w, 3 * i - 2, 3)
	for (i = 2; i <= n; i++) {
		ck = ccc(tk(a[i]))
		if (ck == 0) continue
		c = a[i]
		for (j = i - 1; j >= 1 && ccc(tk(a[j])) > ck; j--) a[j + 1] = a[j]
		a[j + 1] = c
	}
	w = ""
	for (i = 1; i <= n; i++) w = w a[i]
	return w
}
'

# check_dict FILE OUT: validate the dictionary and write it with
# normalized headwords to OUT.  Blank lines are dropped; anything else
# malformed is reported and nothing is repaired.
check_dict() {
	: >"$2"
	[ -s "$1" ] || return 0
	if command -v iconv >/dev/null 2>&1 &&
		! iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; then
		say "$me: $1 is not valid UTF-8; not changed"
		return 1
	fi
	"$AWK" -v F="$1" -v MSG="$2.err" "$THAI_LIB"'
	BEGIN { thai_init() }
	function bad(why) { printf "%s: %s line %d: %s; not changed\n", ME, F, NR, why > MSG; exit 1 }
	$0 == "" { next }
	{
		if (index($0, "\r")) bad("carriage return")
		n = split($0, f, "\t")
		if (n != 3) bad("expected 3 tab-separated fields, found " n)
		if (f[1] == "" || f[2] == "" || f[3] == "") bad("empty field")
		if (index(f[1], ZW)) bad("headword contains U+200B")
		if (!isword(f[1])) bad("headword is not a Thai word")
		print nfc(f[1]) "\t" f[2] "\t" f[3]
	}' ME="$me" "$1" >"$2" && return 0
	cat "$2.err" 2>/dev/null
	return 1
}

# build_tags: tags file for emil's M-. from the sorted dictionary.
build_tags() {
	if [ "$(dirname "$TAGS")" = "$(dirname "$DICT")" ]; then
		p=$(basename "$DICT")
	else
		p=$(cd "$(dirname "$DICT")" && pwd)/$(basename "$DICT")
	fi
	{
		printf '!_TAG_FILE_FORMAT\t1\t/original ctags format/\n'
		printf '!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted/\n'
		"$AWK" -F "$TAB" -v P="$p" '{ print $1 "\t" P "\t" NR }' "$DICT"
	} >"$TAGS.tmp.$$" && mv -f "$TAGS.tmp.$$" "$TAGS"
}

# replace_dict SORTED: atomically replace the dictionary, keeping its mode.
replace_dict() {
	tmp="$(dirname "$DICT")/.$(basename "$DICT").tmp.$$"
	if cp -p "$DICT" "$tmp" && cat "$1" >"$tmp" && mv -f "$tmp" "$DICT"; then
		return 0
	fi
	rm -f "$tmp"
	say "$me: could not write $DICT"
	return 1
}

# commit: merge accepted entries into the dictionary.  It is re-read
# here because it may have changed while the LLM was working.
commit() {
	check_dict "$DICT" "$T/dict.now" || return 1
	"$AWK" -F "$TAB" -v ADDED="$T/added" '
	!($1 in seen) { seen[$1] = 1; print; if (FILENAME == ACC) print > ADDED }
	' ACC="$T/accepted" "$T/dict.now" "$T/accepted" >"$T/merged"
	[ -s "$T/added" ] || return 0
	sort -t "$TAB" -k1,1 "$T/merged" >"$T/sorted" || return 1
	replace_dict "$T/sorted" || return 1
	build_tags || say "$me: could not write $TAGS"
	if [ -z "$nolog" ]; then
		src=$(printf '%s' "$source" | tr '\t\n' '  ')
		d=$(date +%Y-%m-%d)
		"$AWK" -v D="$d" -v S="$src" '{ print D "\t" $0 "\t" S }' \
			"$T/added" >>"$LOG" || say "$me: could not append to $LOG"
	fi
}

# reindex: check, dedupe (keeping the first), sort, rebuild tags.
reindex() {
	check_dict "$DICT" "$T/dict.now" || return 1
	"$AWK" -F "$TAB" -v DUPS="$T/dups" '
	!($1 in seen) { seen[$1] = 1; print; next }
	{ print > DUPS }' "$T/dict.now" >"$T/dedup"
	sort -t "$TAB" -k1,1 "$T/dedup" >"$T/sorted" || return 1
	n=$(wc -l <"$T/sorted" | tr -d ' ')
	if cmp -s "$T/sorted" "$DICT"; then
		say "$DICT: $n entries, already sorted and unique."
	else
		replace_dict "$T/sorted" || return 1
		say "$DICT: $n entries, rewritten sorted and normalized."
	fi
	if [ -s "$T/dups" ]; then
		say "Removed $(wc -l <"$T/dups" | tr -d ' ') duplicate headwords (kept the first):"
		cat "$T/dups"
	fi
	if build_tags; then say "$TAGS rebuilt."; else say "$me: could not write $TAGS"; fi
}

# ---- options -------------------------------------------------------------
source='' nolog='' dry='' reindex=''
while [ $# -gt 0 ]; do
	case $1 in
	-s) [ $# -ge 2 ] || usage; source=$2; shift ;;
	-L) nolog=1 ;;
	-n) dry=1 ;;
	-R) reindex=1 ;;
	-h | --help) usage ;;
	--) shift; break ;;
	-?*) say "$me: unknown option $1"; usage ;;
	*) break ;;
	esac
	shift
done
[ $# -le 1 ] || usage
file=${1:-}

T=$(mktemp -d "${TMPDIR:-/tmp}/n-thai-vocab.XXXXXX") || die "mktemp failed"
jobs_running=
cleanup() {
	for p in $jobs_running; do kill "${p%%:*}" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

pick_awk
mkdir -p "$(dirname "$DICT")" || die "cannot create $(dirname "$DICT")"
[ -e "$DICT" ] || : >"$DICT" || die "cannot create $DICT"

if [ -n "$reindex" ]; then
	reindex
	exit
fi

# ---- read and tokenize ---------------------------------------------------
if [ -n "$file" ]; then
	cat "$file" >"$T/in" || die "cannot read $file"
else
	cat >"$T/in"
fi
if command -v iconv >/dev/null 2>&1 &&
	! iconv -f UTF-8 -t UTF-8 "$T/in" >/dev/null 2>&1; then
	die "input is not valid UTF-8"
fi
check_dict "$DICT" "$T/dict.norm" || exit 1

# tokens: unique normalized words in order of first occurrence.
# skipped: runs too long to be one word (missing boundaries).
# stats: "has-thai has-zw".
"$AWK" -v MAXLEN="$MAXLEN" -v SKIP="$T/skipped" -v STATS="$T/stats" "$THAI_LIB"'
BEGIN { thai_init() }
function emit(w) {
	if (!isword(w)) return
	w = nfc(w)
	if (w in seen) return
	seen[w] = 1
	if (length(w) / 3 > MAXLEN) print w > SKIP
	else print w
}
{
	s = $0; L = length(s); i = 1; cur = ""
	if (index(s, ZW)) zw = 1
	while (i <= L) {
		if (isthaiat(s, i)) {
			thai = 1; c = substr(s, i, 3); i += 3
			if (istok(tk(c))) { cur = cur c; continue }
		} else i += (substr(s, i, 3) == ZW) ? 3 : 1
		if (cur != "") { emit(cur); cur = "" }
	}
	if (cur != "") emit(cur)
}
END { print thai + 0, zw + 0 > STATS }
' "$T/in" >"$T/tokens"

read -r has_thai has_zw <"$T/stats"
if [ "$has_thai" != 1 ] || { [ ! -s "$T/tokens" ] && [ ! -s "$T/skipped" ]; }; then
	say "No Thai words found."
	exit 0
fi
[ "$has_zw" = 1 ] ||
	die "the text has no U+200B word boundaries; annotate it first with n-thai-zw.sh (Ctrl-u Alt-| in emil)"

# (getline, not FNR == NR: that misfires when the dictionary is empty)
"$AWK" -F "$TAB" -v D="$T/dict.norm" '
BEGIN { while ((getline l < D) > 0) { split(l, f, "\t"); k[f[1]] = 1 } }
!($0 in k)' "$T/tokens" >"$T/unknown"
ntok=$(wc -l <"$T/tokens" | tr -d ' ')
nunk=$(wc -l <"$T/unknown" | tr -d ' ')
nknown=$((ntok - nunk))

skipped_note() {
	[ -s "$T/skipped" ] || return 0
	say "Skipped $(wc -l <"$T/skipped" | tr -d ' ') unsegmented runs (over $MAXLEN characters; re-annotate with n-thai-zw.sh -f):"
	sed 's/^/  /' "$T/skipped"
}
text_line="Text: $ntok Thai words, $nknown known, $nunk new."

if [ -n "$dry" ]; then
	cat "$T/unknown"
	[ "$nunk" -gt 0 ] && say ""
	say "$text_line"
	skipped_note
	exit 0
fi
if [ "$nunk" = 0 ]; then
	say "$text_line"
	skipped_note
	exit 0
fi

command -v "$NGPT" >/dev/null 2>&1 || die "LLM command not found: $NGPT"

# ---- ask the LLM ---------------------------------------------------------
: >"$T/context"
if [ "$CONTEXT_MAX" -gt 0 ]; then
	"$AWK" "$THAI_LIB"'BEGIN { thai_init() } { print delall($0, ZW) }' "$T/in" >"$T/bare"
	if [ "$(wc -c <"$T/bare")" -le "$CONTEXT_MAX" ]; then
		{ printf '\nCONTEXT\n'; cat "$T/bare"; } >"$T/context"
	fi
fi
"$AWK" -v DIR="$T" -v N="$BATCH" '
(NR - 1) % N == 0 { if (f) close(f); f = sprintf("%s/q.%05d", DIR, ++b); print "WORDS" > f }
{ print > f }
END { print b }' "$T/unknown" >"$T/nbatch"
for q in "$T"/q.*; do cat "$T/context" >>"$q"; done

instruction="You are writing entries for a Thai learner's personal dictionary. The input has a WORDS section, one Thai word per line, and may have a CONTEXT section: the passage the words came from. For every word in WORDS, in the same order, output exactly one line of three fields separated by a single TAB character: the Thai word exactly as given; its romanization; a concise English definition. Output nothing else: no header, numbering, blank lines, markdown or commentary. Romanization: Paiboon style, lowercase, syllables joined by hyphens, no spaces; tones as diacritics on the vowel (mid unmarked, low à, falling â, high á, rising ǎ); vowels ɛ ɔ ə ʉ; long vowels doubled (aa, ɛɛ, ʉʉ); bp for ป and dt for ต. Definition: the meaning used in CONTEXT if given, otherwise the most common practical meaning; a few words on one line; alternatives separated by semicolons; no tabs. Do not add entries for anything not listed in WORDS."

reap_one() {
	set -- $jobs_running
	first=$1
	shift
	jobs_running=$*
	wait "${first%%:*}"
	echo $? >"$T/s.${first#*:}"
}
njobs=0
for q in "$T"/q.*; do
	id=${q##*.}
	"$NGPT" "$instruction" <"$q" >"$T/r.$id" 2>"$T/e.$id" &
	jobs_running="$jobs_running $!:$id"
	njobs=$((njobs + 1))
	[ "$njobs" -ge "$JOBS" ] && { reap_one; njobs=$((njobs - 1)); }
done
while [ -n "$(echo $jobs_running)" ]; do reap_one; done

nb=$(cat "$T/nbatch") bfail=0 firsterr=
: >"$T/raw"
for q in "$T"/q.*; do
	id=${q##*.}
	if [ "$(cat "$T/s.$id")" = 0 ]; then
		cat "$T/r.$id" >>"$T/raw"
		printf '\n' >>"$T/raw"
	else
		bfail=$((bfail + 1))
		[ -n "$firsterr" ] || firsterr=$(head -n 1 "$T/e.$id")
	fi
done
[ "$bfail" = "$nb" ] &&
	die "LLM call failed (${firsterr:-no message}); dictionary unchanged"

# ---- validate ------------------------------------------------------------
"$AWK" -v REQ="$T/unknown" -v ACC="$T/accepted" -v MISS="$T/missing" \
	-v STAT="$T/vstat" "$THAI_LIB"'
BEGIN {
	thai_init()
	while ((getline w < REQ) > 0) { req[w] = 1; order[++nreq] = w }
	close(REQ)
	printf "" > ACC; printf "" > MISS
}
function rej(why) { nrej++; why_n[why]++ }
{
	line = $0
	sub(/\r$/, "", line)
	if (line ~ /^[ \t]*$/ || substr(line, 1, 3) == "```") next
	if (!index(line, "\t") && index(line, "\\t")) gsub(/\\t/, "\t", line)
	if (split(line, f, "\t") != 3) { rej("malformed"); next }
	for (i = 1; i <= 3; i++) { f[i] = trim(delall(f[i], ZW)); gsub(/  +/, " ", f[i]) }
	sub(/^[0-9]+[.)] */, "", f[1])
	if (f[2] == "" || f[3] == "" || !isword(f[1]) || hasthai(f[2])) { rej("malformed"); next }
	hw = nfc(f[1])
	if (!(hw in req)) { rej("not requested"); next }
	if (hw in acc) { rej("duplicate"); next }
	acc[hw] = hw "\t" f[2] "\t" f[3]
}
END {
	for (i = 1; i <= nreq; i++) {
		w = order[i]
		if (w in acc) print acc[w] > ACC
		else print w > MISS
	}
	s = ""
	split("malformed|not requested|duplicate", kinds, "|")
	for (i = 1; i <= 3; i++)
		if (why_n[kinds[i]]) s = s (s == "" ? "" : ", ") why_n[kinds[i]] " " kinds[i]
	print nrej + 0 > STAT
	print s > STAT
}' "$T/raw"
{ read -r nrej; read -r rejwhy; } <"$T/vstat"

report_tail() {
	say "$text_line"
	[ "$nrej" -gt 0 ] && say "Rejected $nrej LLM lines ($rejwhy)."
	[ "$bfail" -gt 0 ] && say "$bfail of $nb LLM calls failed (${firsterr:-no message})."
	if [ -s "$T/missing" ]; then
		say "No entry for: $(tr '\n' ' ' <"$T/missing" | sed 's/ $//')"
	fi
	skipped_note
	return 0
}

if [ ! -s "$T/accepted" ]; then
	say "Nothing added to $DICT."
	report_tail
	exit 1
fi

# ---- commit --------------------------------------------------------------
: >"$T/added"
commit || exit 1

nadd=$(wc -l <"$T/added" | tr -d ' ')
total=$(wc -l <"$DICT" | tr -d ' ')
if [ "$nadd" -gt 0 ]; then
	say "Added $nadd to $DICT ($total entries):"
	cat "$T/added"
	say ""
else
	say "Nothing added to $DICT (already present)."
fi
report_tail
exit 0
