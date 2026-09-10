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

## n-fetch-md.sh

Fetch a webpage and translate it to Markdown using Pandoc.
Lossy with respect to HTML and Javascript.

Usage: 
```

```

## n-gpg.sh

Decrypt GNU PGP encrypted text without touching disk.

Usage: 
```

```
