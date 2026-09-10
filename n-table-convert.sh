#!/bin/sh
# n-table-convert.sh
#
# Named after Emacs' org-table-convert-region (C-c |).
#
# Convert CSV, TSV, or JSON on stdin into an aligned Markdown or Org-mode
# table. The input format is auto-detected:
#
#   JSON  first non-blank character is '[' or '{'
#   TSV   first non-blank line contains a tab
#   CSV   anything else
#
# The first CSV/TSV row is the header. CSV follows RFC 4180: quoted
# fields may contain commas, doubled quotes ("") and line breaks. TSV is
# split on tabs only, with no quote processing.
#
# JSON may be an array of objects (header = union of keys in first-seen
# order), a single object, an array of arrays (first row = header), an
# array of scalars, or JSON Lines. Nested objects/arrays are shown as
# compact JSON; null becomes an empty cell.
#
# Line breaks inside a cell become spaces. A literal '|' is written as
# \| in Markdown and \vert{} in Org so it can't split the cell.
#
# This script only builds the rows; padding and right-aligning numeric
# columns is done by n-table-align.awk, looked for next to this script
# and then on $PATH.
#
# Usage:
#   cat data.csv  | n-table-convert.sh --md  > table.md
#   cat data.tsv  | n-table-convert.sh --org > table.org
#   cat data.json | n-table-convert.sh --md  > table.md
#
# Requires: awk, n-table-align.awk; jq (JSON input only)

set -eu

prog=n-table-convert.sh

usage() {
    echo "usage: $prog --md|--org < data.{csv,tsv,json}" >&2
    exit 2
}

[ $# -eq 1 ] || usage
case "$1" in
    --md)  fmt=md ;;
    --org) fmt=org ;;
    -h|--help) usage ;;
    *) usage ;;
esac

# locate the aligner: alongside this script first, then on PATH
align=$(dirname "$0")/n-table-align.awk
if [ ! -f "$align" ]; then
    align=$(command -v n-table-align.awk 2>/dev/null) || {
        echo "$prog: n-table-align.awk not found next to $0 or on PATH" >&2
        exit 1
    }
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/n-table-convert.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp"

# ---- detect format --------------------------------------------------------
kind=$(awk '
    NR == 1 { sub(/^\357\273\277/, "") }          # UTF-8 BOM
    {
        line = $0
        sub(/^[ \t\r]+/, "", line)
        if (line == "") next
        c = substr(line, 1, 1)
        if (c == "[" || c == "{") print "json"
        else if (index($0, "\t")) print "tsv"
        else print "csv"
        exit
    }' "$tmp")

if [ -z "$kind" ]; then
    echo "$prog: no input on stdin" >&2
    exit 1
fi

# ---- parse into rows: cells separated by \037, one row per line -----------
to_rows() {
    case "$kind" in
    json)
        command -v jq >/dev/null 2>&1 || {
            echo "$prog: jq is required for JSON input" >&2
            exit 1
        }
        # -s slurps, so a single document and JSON Lines both arrive
        # as one array; unwrap the single-document case.
        jq -rs '
            def cell:
                if . == null then ""
                elif type == "string" then .
                elif type == "object" or type == "array" then tojson
                else tostring end
                | gsub("[\r\n\t\u001f]+"; " ");
            def row: map(cell) | join("\u001f");

            (if length == 1 and (.[0] | type) == "array" then .[0]
             else . end) as $rows
            | if ($rows | length) == 0 then empty
              elif all($rows[]; type == "object") then
                  ($rows | reduce (.[] | keys_unsorted[]) as $k
                      ([]; if index([$k]) then . else . + [$k] end)) as $cols
                  | ($cols | row),
                    ($rows[] as $r | $cols | map($r[.]) | row)
              elif all($rows[]; type == "array") then
                  $rows[] | row
              else
                  "value", ($rows[] | cell)
              end
        ' "$tmp"
        ;;
    tsv)
        awk '
            NR == 1 { sub(/^\357\273\277/, "") }
            {
                sub(/\r$/, "")
                if ($0 == "") next
                gsub(/\037/, " "); gsub(/\t/, "\037")
                print
            }' "$tmp"
        ;;
    csv)
        awk '
            function end_field() {
                row = row (nf++ ? "\037" : "") field
                field = ""; quoted = 0
            }
            NR == 1 { sub(/^\357\273\277/, "") }
            {
                line = $0
                sub(/\r$/, "", line)          # CRLF; a CR before a quoted line break goes too
                gsub(/\037/, " ", line)

                # fast path: nothing quoted on this line
                if (!inq && index(line, "\"") == 0) {
                    if (line == "") next
                    gsub(/,/, "\037", line)
                    print line
                    next
                }

                n = length(line)
                for (i = 1; i <= n; i++) {
                    ch = substr(line, i, 1)
                    if (inq) {
                        if (ch == "\"") {
                            if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                            else inq = 0
                        } else field = field ch
                    } else if (ch == "\"" && !quoted && field ~ /^[ \t]*$/) {
                        field = ""; inq = 1; quoted = 1   # opening quote
                    } else if (ch == ",") {
                        end_field()
                    } else field = field ch               # includes stray quotes
                }

                if (inq) {                  # line break inside quoted field
                    field = field " "
                    next
                }
                end_field()
                print row
                row = ""; nf = 0
            }
            END {
                if (inq) {
                    print "n-table-convert.sh: unterminated quoted field at end of input" > "/dev/stderr"
                    end_field(); print row
                }
            }' "$tmp"
        ;;
    esac
}

# ---- emit a raw pipe table and hand it to the aligner ---------------------
to_rows | awk -v fmt="$fmt" '
    # literal replace; avoids gsub backslash quirks between awks
    function esc_pipes(s,    r, i) {
        r = ""
        while ((i = index(s, "|")) > 0) {
            r = r substr(s, 1, i - 1) bar
            s = substr(s, i + 1)
        }
        return r s
    }
    BEGIN {
        FS = "\037"
        bar = (fmt == "org") ? "\\vert{}" : "\\|"
    }
    {
        n = NF ? NF : 1                    # empty line = one empty cell
        out = "|"
        for (i = 1; i <= n; i++) {
            out = out " " esc_pipes($i) " |"
        }
        print out
        if (++rows == 1) {                 # separator under the header
            out = "|"
            for (i = 1; i <= n; i++)
                out = out "---" (fmt == "org" ? (i < n ? "+" : "|") : "|")
            # org separator needs a "+" for the aligner to recognise it
            if (fmt == "org" && n == 1) out = "|---+---|"
            print out
        }
    }' | awk -f "$align"
