#!/bin/sh
# n-fetch-md.sh
#
# Fetch a URL and convert its HTML content to Markdown, stripping
# scripts, styles, nav/header/footer chrome, and noisy attributes
# that would otherwise clutter the output.
#
# github.com/OWNER/REPO/blob/REF/PATH URLs are rewritten to their
# raw.githubusercontent.com equivalent and passed through unchanged
# -- that's already the source file, so converting the surrounding
# HTML page would only introduce noise and loss.
#
# Usage:
#   echo "https://example.com" | n-fetch-md.sh > out.md
#   n-fetch-md.sh <<< "example.com"        # scheme is optional
#
# Requires: curl, pandoc, perl

set -eu

url=$(head -n1)

if [ -z "$url" ]; then
    echo "n-fetch-md.sh: no URL provided on stdin" >&2
    exit 1
fi

case "$url" in
    http://*|https://*) ;;
    *) url="https://$url" ;;
esac

# github.com blob URL -> raw.githubusercontent.com, and just print it
case "$url" in
    https://github.com/*/*/blob/*)
        raw_url=$(printf '%s' "$url" \
            | sed -E 's#^https://github\.com/([^/]+)/([^/]+)/blob/#https://raw.githubusercontent.com/\1/\2/#')
        curl -sL --fail -A "Mozilla/5.0 (compatible; n-fetch-md/1.0)" "$raw_url" || {
            echo "n-fetch-md.sh: failed to fetch $raw_url" >&2
            exit 1
        }
        exit 0
        ;;
esac

html=$(curl -sL \
            --compressed \
            -A "Mozilla/5.0 (compatible; n-fetch-md/1.0)" \
            --fail \
            "$url") || {
    echo "n-fetch-md.sh: failed to fetch $url" >&2
    exit 1
}

printf '%s' "$html" \
| perl -0777 -pe '
    # drop non-content elements entirely, tag and contents
    s/<script\b[^>]*>.*?<\/script>//gis;
    s/<style\b[^>]*>.*?<\/style>//gis;
    s/<svg\b[^>]*>.*?<\/svg>//gis;
    s/<noscript\b[^>]*>.*?<\/noscript>//gis;
    s/<nav\b[^>]*>.*?<\/nav>//gis;
    s/<header\b[^>]*>.*?<\/header>//gis;
    s/<footer\b[^>]*>.*?<\/footer>//gis;
    s/<form\b[^>]*>.*?<\/form>//gis;
    s/<!--.*?-->//gs;
    # collapse embedded data: URIs so they do not bloat output
    s/(src|href)="data:[^"]*"/$1="#"/gis;
    # strip attributes pandoc would otherwise carry into markdown
    # verbatim as {.class #id data-...} noise
    s/\s(class|id|style|role|data-[a-z-]+|aria-[a-z-]+|analytics-event|hydro-click(?:-hmac)?|tabindex|on[a-z]+)="[^"]*"//gis;
' \
| pandoc -f html-native_divs-native_spans -t markdown --wrap=none --strip-comments
