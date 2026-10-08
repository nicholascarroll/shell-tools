#!/bin/sh
# gpt: pipe text through the GPT API with an instruction
# Usage: echo "hello" | n-gpt.sh [-c [FILE]] "translate to Spanish"
#
# Each call is kept in ~/chats/last.eld, replacing the one there.  -c
# continues the latest chat, or FILE (.eld may be left off): its messages
# are sent before the new one, and the exchange is added to it.
# Continuing last.eld makes it a chat of its own, named from when it
# started and its first instruction.  ~/chats/.latest holds the path of
# the chat used last.  The chat files and what is sent are specified in
# CHATS.md of shell.nicks.house, whose n-gpt.sh works the same way.
#
# Environment: OPENAI_API_KEY (required), OPENAI_MODEL (default
# gpt-5.6-luna).  Needs curl, jq and awk.

[ -z "$OPENAI_API_KEY" ] && {
    echo "OPENAI_API_KEY not set" >&2
    exit 1
}

me=n-gpt.sh
usage() {
    echo "usage: $me [-c [FILE]] \"instruction\"   (pipe the text in; -c continues the latest chat in ~/chats, or FILE)" >&2
    exit 2
}
fail() {
    printf '%s: %s\n' "$me" "$*" >&2      # printf: dash's echo would rewrite backslashes
    exit 1
}

cont=; file=
if [ "$1" = -c ]; then
    cont=1; shift
    # a FILE only when the instruction follows it: -c "explain that" continues the latest
    case $1 in -*) ;; *) [ $# -ge 2 ] && { file=$1; shift; } ;; esac
fi
instruction=$1
[ -n "$instruction" ] || usage
# The text, exactly as read (no newlines dropped); from a terminal, none.
if [ -t 0 ]; then input=; else input=$(cat; printf x); input=${input%x}; fi

chats=$HOME/chats
latest=$chats/.latest
last=$chats/last.eld

# parse FILE: the chat as JSON, {"end": offset of the closing paren,
# "started": ..., "history": [{role, instruction?, text}, ...]}, or
# "line N: problem" on standard error and status 1.  Only the Lisp subset
# of CHATS.md is accepted.  Bytes throughout, so offsets suit head -c.
parse() {
    # awk adds a line feed after the last line; nonl says it was not there.
    nonl=0; [ -n "$(tail -c 1 "$1")" ] && nonl=1
    LC_ALL=C awk -v nonl="$nonl" '
function fail(msg, at) { printf "line %d: %s\n", (at ? at : line), msg > "/dev/stderr"; bad = 1; exit 1 }
function c() { return substr(src, i, 1) }
function skip(  ch) {
    for (;;) {
        ch = c()
        if (ch == "\n") { line++; i++ }
        else if (ch == " " || ch == "\t" || ch == "\r") i++
        else if (ch == ";") { while (i <= n && c() != "\n") i++ }
        else return
    }
}
function word(  w) {
    if (c() !~ /[a-z]/) return ""
    w = ""
    while (i <= n && c() ~ /[a-z-]/) { w = w c(); i++ }
    return w
}
function str(  s, ch, e, start) {
    start = line
    if (c() != "\"") fail("expected a string (\"…\")")
    i++; s = ""
    for (;;) {
        if (i > n) fail("unterminated string", start)
        ch = c(); i++
        if (ch == "\"") return s
        if (ch == "\n") line++
        if (ch == "\\") {
            e = c(); i++
            if (e == "\"" || e == "\\") s = s e
            else fail("unsupported escape \\" (e == "\n" ? "<newline>" : e) " in a string: only \\\" and \\\\ are allowed")
        } else s = s ch
    }
}
function json(s,  out, k, ch) {
    out = ""
    for (k = 1; k <= length(s); k++) {
        ch = substr(s, k, 1)
        if (ch == "\\") out = out "\\\\"
        else if (ch == "\"") out = out "\\\""
        else if (ch == "\n") out = out "\\n"
        else if (ch == "\r") out = out "\\r"
        else if (ch == "\t") out = out "\\t"
        else if (ch in ctl) out = out sprintf("\\u%04x", ctl[ch])
        else out = out ch
    }
    return "\"" out "\""
}
BEGIN { for (k = 1; k < 32; k++) ctl[sprintf("%c", k)] = k }
{ src = src $0 "\n" }
END {
    if (bad) exit 1
    if (nonl) src = substr(src, 1, length(src) - 1)
    n = length(src); i = 1; line = 1
    skip()
    if (c() != "(") fail("expected (chat …)")
    i++; skip()
    if (word() != "chat") fail("expected (chat …)")
    skip(); started = ""; has_started = 0
    if (c() == ":") {
        i++; k = word()
        if (k != "started") fail("unknown keyword :" k " in (chat …): only :started")
        skip(); started = str(); has_started = 1
    }
    m = 0
    for (;;) {
        skip()
        if (i > n) fail("missing ) at the end of (chat …)")
        if (c() == ")") break
        if (c() != "(") fail("expected (user …) or (assistant …)")
        at = line; i++; skip()
        role = word()
        if (role == "user") kw = "instruction"
        else if (role == "assistant") kw = "model"
        else fail("expected (user …) or (assistant …)")
        m++; R[m] = role; L[m] = at; I[m] = ""; HI[m] = 0; seen = 0
        for (;;) {
            skip()
            if (c() != ":") break
            i++; k = word()
            if (k != kw) fail("unknown keyword :" k " in (" role " …): only :" kw)
            if (seen) fail(":" k " given twice")
            seen = 1; skip(); v = str()
            if (role == "user") { I[m] = v; HI[m] = 1 }
        }
        T[m] = str()
        skip()
        if (c() != ")") fail("expected ) after the text of (" role " …)")
        i++
    }
    end = i - 1
    i++; skip()
    if (i <= n) fail("text after the end of (chat …)")
    for (k = 1; k <= m; k++) {
        if (R[k] != (k % 2 ? "user" : "assistant"))
            fail(k % 2 ? (k > 1 ? "two assistant messages in a row" : "a chat starts with (user …)") : "two user messages in a row", L[k])
        if (R[k] == "assistant" && T[k] == "") fail("an empty (assistant …) reply", L[k])
        if (R[k] == "user" && T[k] == "" && !HI[k]) fail("a (user …) with neither an instruction nor text", L[k])
    }
    printf "{\"end\":%d,\"started\":%s,\"history\":[", end, has_started ? json(started) : "null"
    for (k = 1; k <= m; k++)
        printf "%s{\"role\":\"%s\"%s,\"text\":%s}", (k > 1 ? "," : ""), R[k], (HI[k] ? ",\"instruction\":" json(I[k]) : ""), json(T[k])
    print "]}"
}' "$1"
}

# The chat to continue: its path, as shown, and its parse.
chat=; history='[]'
if [ -n "$cont" ]; then
    if [ -n "$file" ]; then
        chat=$file; shown=$file
        [ ! -e "$chat" ] && [ -e "$chat.eld" ] && { chat=$chat.eld; shown=$shown.eld; }
    else
        [ -r "$latest" ] || fail "no chat to continue yet: run it without -c first"
        chat=$(cat "$latest"); shown=$chat
    fi
    [ -r "$chat" ] && [ -f "$chat" ] || fail "$shown: no such chat"
    parsed=$(parse "$chat" 2>&1) || fail "$shown: $parsed"
    history=$(printf '%s' "$parsed" | jq -c .history)
fi

system="You are a plain text filter inside a text editor. Apply the user's instruction to the provided text. Output only the result with no explanation, no markdown fencing, and no preamble."

# The history, then the new message: a user message is "Instruction: I",
# then a blank line and the text if there is any (CHATS.md).
payload=$(jq -n \
  --arg model "${OPENAI_MODEL:-gpt-5.6-luna}" \
  --arg system "$system" \
  --arg instruction "$instruction" \
  --arg input "$input" \
  --argjson history "$history" \
  'def content: if .instruction then "Instruction: \(.instruction)" + (if .text != "" then "\n\n\(.text)" else "" end) else .text end;
   {
    "model": $model,
    "messages": ([{"role": "system", "content": $system}]
      + [$history[] | {role, content: (if .role == "user" then content else .text end)}]
      + [{"role": "user", "content": ({instruction: $instruction, text: $input} | content)}])
  }')

response=$(curl -sS https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$payload")

# Extract content or error
error=$(printf '%s' "$response" | jq -r '.error.message // empty')
if [ -n "$error" ]; then
    printf 'Error: %s\n' "$error" >&2
    exit 1
fi
printf '%s' "$response" | jq -e '.choices[0].message.content | strings' >/dev/null 2>&1 || {
    echo "Error: no answer from OpenAI" >&2
    exit 1
}
reply=$(printf '%s' "$response" | jq -r '.choices[0].message.content'; printf x); reply=${reply%?x}
model=$(printf '%s' "$response" | jq -r '.model // empty')
printf '%s\n' "$reply"

# Keep the exchange (CHATS.md): in last.eld, or added to the chat, which
# is a new one when it was last.eld; then that is the latest.  Files are
# replaced whole, so calls running at the same time cannot mix them.
exchange=$(jq -jn --arg i "$instruction" --arg t "$input" --arg m "${model:-${OPENAI_MODEL:-gpt-5.6-luna}}" --arg r "$reply" \
  'def q: "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")) + "\"";
   "\n (user :instruction \($i|q)\n  \($t|q))\n (assistant :model \($m|q)\n  \($r|q))"'; printf x); exchange=${exchange%x}
keep() {
    mkdir -p "$chats" || return 1
    if [ -z "$chat" ]; then
        dest=$last
        tmp=$(mktemp "$chats/.tmp.XXXXXX") || return 1
        { printf ';; -*- mode: lisp-data -*-\n;; A chat for n-gpt.sh and n-claude.sh: edit freely, keeping the format (CHATS.md).\n'
          printf '(chat :started "%s"%s)\n' "$(date '+%Y-%m-%d %H:%M')" "$exchange"; } >"$tmp" || return 1
    else
        dest=$chat
        case $chat in /*) abs=$chat ;; *) abs=$PWD/$chat ;; esac
        if [ "$abs" = "$last" ]; then
            first=$(printf '%s' "$parsed" | jq -r '[.history[] | select(.instruction) | .instruction][0] // empty')
            started=$(printf '%s' "$parsed" | jq -r '.started // empty')
            dest=$chats/$(name "${first:-$instruction}" "$started")
        fi
        end=$(printf '%s' "$parsed" | jq .end)
        tmp=$(mktemp "$chats/.tmp.XXXXXX") || return 1
        { head -c "$end" "$chat"; printf '%s' "$exchange"; tail -c +"$((end + 1))" "$chat"; } >"$tmp" || return 1
    fi
    mv "$tmp" "$dest" || return 1
    case $dest in /*) ;; *) dest=$PWD/$dest ;; esac
    tmp=$(mktemp "$chats/.tmp.XXXXXX") && printf '%s\n' "$dest" >"$tmp" && mv "$tmp" "$latest"
}
# name INSTRUCTION STARTED: a free file name for a chat continued from
# last.eld, YYYY-MM-DD-HHMM-WORDS.eld, from its start (or now) and the
# instruction's words, at most 40 characters of them.
name() {
    case $2 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) when=$(printf '%s' "$2" | tr ' ' '-' | tr -d ':') ;;
    *) when=$(date '+%Y-%m-%d-%H%M') ;;
    esac
    slug=$(printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr 'A-Z' 'a-z' | LC_ALL=C sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//')
    [ ${#slug} -gt 40 ] && slug=$(printf '%s' "$slug" | cut -c1-41 | sed 's/-[^-]*$//')
    [ -n "$slug" ] || slug=chat
    n=1; f=$when-$slug.eld
    while [ -e "$chats/$f" ]; do n=$((n + 1)); f=$when-$slug-$n.eld; done
    printf '%s' "$f"
}
keep || { rm -f "$tmp"; fail "the answer is not kept in ~/chats"; }
