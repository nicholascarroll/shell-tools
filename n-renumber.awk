#!/usr/bin/awk -f
# n-renumber.aw
#
# Renumbers "N. " / "N) " ordered-list items, per indentation level, for
# both Markdown and Org-mode. A list is only touched once it has at
# least 3 items at that level.  Renumbering continues from whatever number the
# first item in the (qualifying) list used, not necessarily 1.
#
# Everything else (headings, prose, tables, code) passes through
# unchanged.
#
# Usage:
#   awk -f n-renumber.awk file.md  > out.md
#   cat notes.org | awk -f n-renumber.awk > out.org
#
# A list block ends at two consecutive blank lines, or at a line
# indented no more than the outermost open list item. Anything indented
# *more* than that is treated as a continuation (a wrapped paragraph
# inside a list item), so it doesn't end the block.

function try_list_item(line,    indent, rest, marker, mlen, i, ch) {
    if (match(line, /^[ \t]*/)) indent = substr(line, 1, RLENGTH)
    else indent = ""
    rest = substr(line, length(indent) + 1)
    if (!match(rest, /^[0-9]+[.)][ \t]+/)) return 0
    marker = substr(rest, 1, RLENGTH)
    li_content = substr(rest, RLENGTH + 1)
    mlen = length(marker)
    for (i = 1; i <= mlen; i++) {
        ch = substr(marker, i, 1)
        if (ch == "." || ch == ")") {
            li_num = substr(marker, 1, i - 1) + 0
            li_delim = ch
            break
        }
    }
    li_indent = indent
    return 1
}

function leading_len(line) {
    if (match(line, /^[ \t]*/)) return RLENGTH
    return 0
}

function list_block_reset() {
    bn = 0
    depth = 0
    blank_count = 0
    inst_counter = 0
    delete blines
    delete btype
    delete bindent
    delete bdelim
    delete bnum
    delete bcontent
    delete binst
    delete boccurrence
    delete count_per_inst
    delete firstnum_per_inst
    delete list_len
    delete list_inst
}

function flush_list_block(    i, inst, newnum) {
    if (bn == 0) { in_list = 0; return }
    for (i = 1; i <= bn; i++) {
        if (btype[i] == "item") {
            inst = binst[i]
            if (count_per_inst[inst] >= 3)
                newnum = firstnum_per_inst[inst] + boccurrence[i] - 1
            else
                newnum = bnum[i]
            print bindent[i] newnum bdelim[i] " " bcontent[i]
        } else {
            print blines[i]
        }
    }
    list_block_reset()
    in_list = 0
}

{
    if (try_list_item($0)) {
        if (!in_list) { in_list = 1; list_block_reset() }
        indentlen = length(li_indent)
        while (depth > 0 && indentlen < list_len[depth]) depth--
        if (depth > 0 && indentlen == list_len[depth]) {
            inst = list_inst[depth]
            count_per_inst[inst]++
            occ = count_per_inst[inst]
        } else {
            depth++
            list_len[depth] = indentlen
            inst_counter++
            inst = inst_counter
            list_inst[depth] = inst
            count_per_inst[inst] = 1
            firstnum_per_inst[inst] = li_num
            occ = 1
        }
        bn++
        btype[bn] = "item"
        bindent[bn] = li_indent
        bdelim[bn] = li_delim
        bnum[bn] = li_num
        bcontent[bn] = li_content
        binst[bn] = inst
        boccurrence[bn] = occ
        blank_count = 0
        next
    }

    if (in_list) {
        if ($0 ~ /^[ \t]*$/) {
            blank_count++
            bn++; btype[bn] = "blank"; blines[bn] = $0
            if (blank_count >= 2) flush_list_block()
        } else {
            indentlen = leading_len($0)
            if (indentlen > list_len[1]) {
                blank_count = 0
                bn++; btype[bn] = "other"; blines[bn] = $0
            } else {
                flush_list_block()
                print $0
            }
        }
        next
    }

    print $0
}

END {
    if (in_list) flush_list_block()
}
