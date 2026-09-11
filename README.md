# shell-tools

Miscellaneous Unix shell tools

## n-table-align.awk

Align Markdown or Org mode tables.

Number columns get right aligned.

Usage:
```
awk -f n-table-align.awk file.md  > out.md
n-table-align.awk file.md > out.md
cat notes.org | n-table-align.awk > out.org
```

## n-renumber.awk

Renumbers numbered lists to sequential in Markdown or Org.

Usage: same as n-table-align.awk.

## n-gpt.sh

Pipe text through GPT API with an instruction

Usage: 
```
echo "hello" | n_gpt.sh "translate to Spanish"
```

## n-thai-zw.sh

Insert U+200B ZERO WIDTH SPACE between Thai words, so the text looks
unchanged but word motion, word wrap and tag lookup see word boundaries.
The LLM (via n-gpt.sh) proposes the boundaries; its output is accepted
only if removing them gives back the input byte for byte. On any
failure the text is passed through unchanged. Lines that already
contain U+200B are left alone.

Usage:
```
n-thai-zw.sh lesson.txt > annotated.txt
n-thai-zw.sh -i lesson.txt          # in place
n-thai-zw.sh -f -i lesson.txt       # redo existing boundaries
```
In emil: mark a region, `Ctrl-u Alt-|` `n-thai-zw.sh`.

## n-thai-vocab.sh

Build a personal Thai-English vocabulary from what you read. Takes
annotated Thai text, sends the words not yet in `~/thai/dict.tsv` to
the LLM in batches, validates the entries (Thai headword, Paiboon
romanization, short English definition), adds them, re-sorts the
dictionary and rebuilds `~/thai/tags`, so `M-.` on a Thai word in emil
jumps to its entry. New words are also appended to
`~/thai/acquired.log` with the date and source.

Usage:
```
n-thai-vocab.sh -s "chapter 3" < annotated.txt
n-thai-vocab.sh -n < annotated.txt   # list unknown words only
n-thai-vocab.sh -R                   # check, sort, dedupe, re-index
```
In emil: mark a region, `Alt-|` `n-thai-vocab.sh -s "chapter 3"`.
The new entries and a summary appear in `*Shell Output*`.

The dictionary is replaced atomically; if it is open in emil, emil
asks before saving over the change. See the header of each script for
environment variables.

## n-fetch-md.sh

Fetch a webpage and translate it to Markdown using Pandoc.
Lossy with respect to HTML and Javascript.

Usage: 
```

```

## n-gpg.sh

Encrypt and decrypt GNU PGP encrypted text without touching disk.

-e encrypt  
-d decrypt  
-b Beorg  compatible  

Usage: 

```
echo "-----BEGIN PGP MESSAGE-----

0mkBG7/U9aH06lvFmoZD/tYYlaIDqCkkuEjp+EET0i2HGLZQQfg0OYql1B/TiBUz
qPXJeUZy5JgLGK1s7dS0OdA768JpyKbhG5Jkr+aITWB3I2PWpytwxQoA6OAvDKs4
TRhjXsJOP3xGZZM=
=fJY4
-----END PGP MESSAGE-----
" | n-gpg.sh -db     # password is opensesame
```


## n-table-convert.sh

Convert CSV, TSV, or JSON data into an aligned Markdown or Org mode table.

The input format is auto-detected.  JSON can be an array of objects,
an array of arrays, a single object, or JSON Lines.

Alignment is done by `n-table-align.awk`, which must be in the same
directory or on `PATH`. JSON input requires `jq`.

Usage:
```
cat data.csv  | n-table-convert.sh --md > table.md
cat data.tsv  | n-table-convert.sh --org > table.org
cat data.json | n-table-convert.sh --md > table.md
```

