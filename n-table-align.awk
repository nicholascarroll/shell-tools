#!/usr/bin/awk -f
# n-table-align.awk
#
# Reads text on stdin (or files given as args), passes non-table lines
# through unchanged, and re-pads any pipe tables so columns line up.
# Handles both:
#   Markdown:  | a | b |          separator: |---|:---:|---:|
#   Org-mode:  | a | b |          separator: |---+------|
#
# Any column whose data cells are all numeric (and not already given an
# explicit alignment via a Markdown ":---:" / "---:" separator cell) is
# automatically right-aligned.
# TODO Org's notation for forcing a column's alignment isn't a colon in 
# the separator; it's a cookie like <r> or <r10> placed in any cell of 
# the column, meaning "right-align, width 10."
#
# Usage:
#   awk -f n-table-align.awk file.md  > out.md
#   cat notes.org | awk -f n-table-align.awk > out.org
#

function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

function repeat(ch, n,    s, i) {
    s = ""
    for (i = 0; i < n; i++) s = s ch
    return s
}

function is_tableline(line,    t) {
    t = line
    sub(/^[ \t]*/, "", t)
    sub(/[ \t]*$/, "", t)
    return (t ~ /^\|.*\|$/ && length(t) >= 2)
}

# org-style separator: only dashes/plus signs, at least one '+', no pipes
function is_org_sep(inner) {
    return (inner ~ /^[ \t]*[-+]+[ \t]*$/ && inner ~ /\+/)
}

# a single (already trimmed) cell that looks like a markdown separator cell
function is_md_sep_cell(c) {
    return (c ~ /^:?-+:?$/)
}

# a single (already trimmed) data cell that looks like a plain number:
# optional sign, digits with optional thousands commas, optional decimal
# part, optional trailing percent sign.
function is_numeric_cell(c) {
    return (c ~ /^[+-]?[0-9][0-9,]*(\.[0-9]+)?%?$/)
}

function flush_block() {
    if (nrows == 0) return

    ncols = 0
    for (r = 1; r <= nrows; r++)
        if (!sep[r] && ncell[r] > ncols) ncols = ncell[r]
    if (ncols == 0)
        for (r = 1; r <= nrows; r++)
            if (sep[r] && ncell[r] > ncols) ncols = ncell[r]

    style = "markdown"
    for (r = 1; r <= nrows; r++)
        if (sep[r] && orgsep[r]) { style = "org"; break }

    for (c = 1; c <= ncols; c++) width[c] = 0
    for (r = 1; r <= nrows; r++)
        if (!sep[r])
            for (c = 1; c <= ncell[r]; c++) {
                w = length(cell[r, c])
                if (w > width[c]) width[c] = w
            }

    if (style == "markdown") {
        for (c = 1; c <= ncols; c++) if (width[c] < 3) width[c] = 3
    } else {
        for (c = 1; c <= ncols; c++) if (width[c] < 1) width[c] = 1
    }

    for (c = 1; c <= ncols; c++) { align[c] = "l"; explicit[c] = 0 }
    if (style == "markdown")
        for (r = 1; r <= nrows; r++)
            if (sep[r] && !orgsep[r])
                for (c = 1; c <= ncell[r]; c++) {
                    a = cell[r, c]
                    lc = (substr(a, 1, 1) == ":")
                    rc = (substr(a, length(a), 1) == ":")
                    if (lc && rc) { align[c] = "c"; explicit[c] = 1 }
                    else if (rc) { align[c] = "r"; explicit[c] = 1 }
                    else if (lc) { align[c] = "l"; explicit[c] = 1 }
                }

    # header rows sit before the first separator row and are excluded
    # from the numeric check below (a header like "Score" shouldn't
    # disqualify an otherwise all-numeric data column).
    first_sep = 0
    for (r = 1; r <= nrows; r++) if (sep[r]) { first_sep = r; break }

    # auto right-align columns that are entirely numeric, unless the
    # column already has an explicit Markdown alignment marker.
    for (c = 1; c <= ncols; c++) {
        if (explicit[c]) continue
        has_num = 0; all_num = 1
        for (r = 1; r <= nrows; r++) {
            if (sep[r]) continue
            if (first_sep && r < first_sep) continue
            v = (c <= ncell[r]) ? cell[r, c] : ""
            if (v == "") continue
            has_num = 1
            if (!is_numeric_cell(v)) { all_num = 0; break }
        }
        if (has_num && all_num) align[c] = "r"
    }

    for (r = 1; r <= nrows; r++) {
        out = rowindent[r] "|"
        if (sep[r]) {
            for (c = 1; c <= ncols; c++) {
                if (style == "org") {
                    out = out repeat("-", width[c] + 2) (c < ncols ? "+" : "")
                } else {
                    dashes = width[c] + 2
                    if (align[c] == "c" && dashes >= 2)
                        s = ":" repeat("-", dashes - 2) ":"
                    else if (align[c] == "r")
                        s = repeat("-", dashes - 1) ":"
                    else
                        s = repeat("-", dashes)
                    out = out s "|"
                }
            }
            if (style == "org") out = out "|"
        } else {
            for (c = 1; c <= ncols; c++) {
                v = (c <= ncell[r]) ? cell[r, c] : ""
                pad = width[c] - length(v)
                if (pad < 0) pad = 0
                if (align[c] == "r")
                    out = out " " repeat(" ", pad) v " |"
                else if (align[c] == "c") {
                    lp = int(pad / 2); rp = pad - lp
                    out = out " " repeat(" ", lp) v repeat(" ", rp) " |"
                } else
                    out = out " " v repeat(" ", pad) " |"
            }
        }
        print out
    }

    nrows = 0
    delete cell
    delete ncell
    delete sep
    delete orgsep
    delete rowindent
}

{
    if (is_tableline($0)) {
        line = $0
        indent = line
        sub(/[^ \t].*$/, "", indent)
        sub(/^[ \t]*/, "", line)
        sub(/[ \t]*$/, "", line)
        inner = substr(line, 2, length(line) - 2)

        nrows++
        rowindent[nrows] = indent

        if (is_org_sep(inner)) {
            sep[nrows] = 1
            orgsep[nrows] = 1
            n = split(inner, parts, /\+/)
            ncell[nrows] = n
        } else {
            n = split(inner, parts, /\|/)
            ncell[nrows] = n
            is_sep = 1
            for (i = 1; i <= n; i++) {
                cell[nrows, i] = trim(parts[i])
                if (!is_md_sep_cell(cell[nrows, i])) is_sep = 0
            }
            if (is_sep) { sep[nrows] = 1; orgsep[nrows] = 0 }
        }
    } else {
        flush_block()
        print $0
    }
}

END { flush_block() }
