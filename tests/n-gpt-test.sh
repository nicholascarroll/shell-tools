#!/bin/sh
# n-gpt-test.sh: tests n-gpt.sh's chats (CHATS.md of shell.nicks.house)
# offline: curl is replaced by a fake that records the request and
# answers, and HOME is a temporary directory.
# Usage: sh tests/n-gpt-test.sh   (needs jq; run it with dash too)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home OPENAI_API_KEY=sk-test SENT=$T/sent.json PATH="$T/bin:$PATH"
mkdir -p "$HOME" "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -d ] && printf '%s' "$2" >"$SENT"; shift; done
[ -n "${FAKE_ERROR:-}" ] && { jq -n --arg e "$FAKE_ERROR" '{error: {message: $e}}'; exit 0; }
jq -n --arg r "${FAKE_REPLY:-}" --slurpfile p "$SENT" \
  '{model: "gpt-test", choices: [{message: {content: (if $r != "" then $r else "re: " + $p[0].messages[-1].content end)}}]}'
EOF
chmod +x "$T/bin/curl"
gpt="$here/n-gpt.sh"
chats=$HOME/chats

failed=0
ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1"; printf '  want: %s\n  got:  %s\n' "$3" "$2"; fi; }
sent() { jq -c "$1" "$SENT"; }
files() { (cd "$chats" && ls); }

# A new call: last.eld, replaced each time; nothing else.
out=$(echo hi | "$gpt" 'translate to French'; echo hello | "$gpt" 'translate to Spanish')
check "a call answers" "$out" "re: Instruction: translate to French

hi

re: Instruction: translate to Spanish

hello"
check "the instruction is in the user message, the text after a blank line" "$(sent '.messages')" \
  '[{"role":"system","content":"You are a plain text filter inside a text editor. Apply the user'"'"'s instruction to the provided text. Output only the result with no explanation, no markdown fencing, and no preamble."},{"role":"user","content":"Instruction: translate to Spanish\n\nhello\n"}]'
check "calls without -c keep only last.eld" "$(files)" "last.eld"
check ".latest is last.eld" "$(cat "$chats/.latest")" "$chats/last.eld"
started=$(sed -n 's/^(chat :started "\(.*\)"$/\1/p' "$chats/last.eld")
case $started in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) ok "last.eld records when it started" ;; *) no "last.eld records when it started: $started" ;; esac

# -c: last.eld becomes a chat named from its start and first instruction.
out=$("$gpt" -c 'explain that' </dev/null)
check "-c sends the chat before the new message; no text, the instruction alone" "$(sent '[.messages[1:][] | .content]')" \
  '["Instruction: translate to Spanish\n\nhello\n","re: Instruction: translate to Spanish\n\nhello\n","Instruction: explain that"]'
C1=$(printf '%s' "$started" | tr ' ' - | tr -d :)-translate-to-spanish.eld
check "continuing last.eld makes a chat of its own" "$(files)" "$C1
last.eld"
check "which is the latest" "$(cat "$chats/.latest")" "$chats/$C1"
"$gpt" -c 'and again' </dev/null >/dev/null
check "-c then continues that chat" "$(sent '.messages | length')" 6
check "last.eld is left as it was" "$(grep -c '^ (user' "$chats/last.eld")" 1
echo bye | "$gpt" 'translate to Spanish' >/dev/null
(cd "$chats" && "$gpt" -c "${C1%.eld}" 'one more' </dev/null >/dev/null)
check "-c FILE, without .eld, continues FILE" "$(sent '.messages | length')" 8
check "and it is the latest" "$(cat "$chats/.latest")" "$chats/$C1"
"$gpt" -c "$chats/last" 'again' </dev/null >/dev/null
check "-c ~/chats/last makes another chat" "$(files)" "${C1%.eld}-2.eld
$C1
last.eld"

# Text that is hard to write reads back exactly.
HARD='He said "hi" \ then left.

* a bullet
1) a point :)
(not a list) ;not a comment
"\""	zoë 🎹
'
printf '%s' "$HARD" | FAKE_REPLY="$HARD" "$gpt" 'say "x"' >/dev/null
"$gpt" -c 'next' </dev/null >/dev/null
check "quotes, backslashes, brackets and line breaks read back unchanged" \
  "$(jq -r --arg h "$HARD" '[.messages[1].content == "Instruction: say \"x\"\n\n\($h)", .messages[2].content == $h] | @text' "$SENT")" '[true,true]'

# A hand edit is kept; the exchange goes before the closing paren.
printf ';; mine\n(chat\n  ;; first\n  (user "hello")   (assistant "hola")\n) ; done\n' >"$chats/hand.eld"
"$gpt" -c "$chats/hand.eld" 'explain that' </dev/null >/dev/null
check "comments and layout are kept" "$(head -4 "$chats/hand.eld"; tail -1 "$chats/hand.eld")" ';; mine
(chat
  ;; first
  (user "hello")   (assistant "hola")
  "re: Instruction: explain that")) ; done'
check "a user message without instruction is its text" "$(sent '.messages[1].content')" '"hello"'

# Mistakes are reported with their line, and nothing is sent.
bad() {
    printf '%s' "$1" >"$chats/bad.eld"; rm -f "$SENT"
    err=$("$gpt" -c "$chats/bad.eld" x </dev/null 2>&1 >/dev/null); rc=$?
    if [ "$rc" = 1 ] && [ ! -e "$SENT" ] && [ "$err" = "n-gpt.sh: $chats/bad.eld: $2" ]; then ok "mistake: $2"; else no "mistake: $2"; printf '  got (%s): %s\n' "$rc" "$err"; fi
}
bad '(chat
 (user "a")
 (assistant "b)
' 'line 3: unterminated string'
bad '(chat
 (user "a\nb"))' 'line 2: unsupported escape \n in a string: only \" and \\ are allowed'
bad '(chat
 (user "a")
 (user "b"))' 'line 3: two user messages in a row'
bad '(chat
 (assistant "b"))' 'line 2: a chat starts with (user …)'
bad '(chat
 (user "a")
 (assistant "b")
 (assistant "c"))' 'line 4: two assistant messages in a row'
bad '(chat
 (user "a")
 (assistant ""))' 'line 3: an empty (assistant …) reply'
bad '(chat
 (user ""))' 'line 2: a (user …) with neither an instruction nor text'
bad '(chat
 (user :model "x" "a"))' 'line 2: unknown keyword :model in (user …): only :instruction'
bad '(chat
 (user :instruction "x" :instruction "y" "a"))' 'line 2: :instruction given twice'
bad '(chat
 (user "a" "b"))' 'line 2: expected ) after the text of (user …)'
bad '(chat
 (system "a"))' 'line 2: expected (user …) or (assistant …)'
bad '(chat
 (user a))' 'line 2: expected a string ("…")'
bad '(chat (user "a") (assistant "b")' 'line 1: missing ) at the end of (chat …)'
bad '(chat) (chat)' 'line 1: text after the end of (chat …)'
bad '(conversation)' 'line 1: expected (chat …)'
bad '(chat :start "x")' 'line 1: unknown keyword :start in (chat …): only :started'
bad '' 'line 1: expected (chat …)'

err=$("$gpt" -c nosuch.eld x </dev/null 2>&1); check "-c FILE that does not exist" "$err" "n-gpt.sh: nosuch.eld: no such chat"
rm "$chats/.latest"
err=$("$gpt" -c x </dev/null 2>&1); check "-c with no latest chat" "$err" "n-gpt.sh: no chat to continue yet: run it without -c first"
err=$("$gpt" </dev/null 2>&1); rc=$?; check "no instruction is a usage error" "$rc" 2

# An error leaves the chats as they were.
cp "$chats/last.eld" "$T/before"
err=$(echo x | FAKE_ERROR="Rate limit reached" "$gpt" y 2>&1); rc=$?
check "an error is printed, status 1" "$rc: $err" "1: Error: Rate limit reached"
cmp -s "$chats/last.eld" "$T/before" && ok "an error leaves last.eld alone" || no "an error leaves last.eld alone"

# Calls running at the same time (n-thai-zw.sh) leave a whole last.eld.
for k in 1 2 3 4 5 6 7 8; do echo "$k" | "$gpt" "number $k" >/dev/null & done; wait
"$gpt" -c "$chats/last.eld" check </dev/null >/dev/null && ok "parallel calls leave a chat that parses" || no "parallel calls leave a chat that parses"
check "and no temporary files" "$(cd "$chats" && ls -A | grep -c '^\.tmp')" 0

[ "$failed" = 0 ] && echo "all passed" || echo "$failed FAILED"
[ "$failed" = 0 ]
