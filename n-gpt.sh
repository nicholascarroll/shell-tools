#!/bin/sh
# gpt: pipe text through the GPT API with an instruction
# Usage: echo "hello" | gpt "translate to Spanish"

[ -z "$OPENAI_API_KEY" ] && {
    echo "OPENAI_API_KEY not set" >&2
    exit 1
}

instruction="${1:?Usage: $0 \"instruction\"}"
input=$(cat)

system="You are a plain text filter inside a text editor. Apply the user's instruction to the provided text. Output only the result with no explanation, no markdown fencing, and no preamble."

payload=$(jq -n \
  --arg system "$system" \
  --arg instruction "$instruction" \
  --arg input "$input" \
  '{
    "model": "gpt-5.6-luna",
    "messages": [
      {"role": "system", "content": ($system + "\nInstruction: " + $instruction)},
      {"role": "user", "content": $input}
    ]
  }')

response=$(curl -sS https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$payload")

# Extract content or error
error=$(printf '%s' "$response" | jq -r '.error.message // empty')
if [ -n "$error" ]; then
    echo "Error: $error" >&2
    exit 1
fi

printf '%s' "$response" | jq -r '.choices[0].message.content'
