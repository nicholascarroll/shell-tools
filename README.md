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

## n-to-table.sh
* TODO get the emacs name

Convert CSV, TSV, or JSON data into an aligned Markdown or Org mode table.

The input format is auto-detected.

Usage:
```
cat data.csv  | n-to-table.sh --md > table.md
cat data.tsv  | n-to-table.sh --org > table.org
cat data.json | n-to-table.sh --md > table.md
```

## n-dict.sh

Look up a word using the offline `sdcv` dictionary and print cleaned-up output.

Usage:
```
echo "word" | n-dict.sh
```

## n-sense.sh

Implements a system that provides contextual word lookup, semantic cross-referencing, and definition resolution for prose-based projects. 
The system operates as an extension to a terminal-based text editor (via ctags) and produces static, deterministic, version-controllable artifacts.
The system addresses three distinct lookup needs that arise during reading and writing:
	1.	Where a term is formally established within a project.
	2.	How a term is actually used across the project.
	3.	What a term means according to an external reference standard.

Hybrid Sense Induction and Grounded Definition Generation.
