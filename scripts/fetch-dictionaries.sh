#!/bin/bash
# Downloads open-source Hunspell spelling dictionaries for languages the Mac doesn't check
# itself, into the folder KPTN.SUB reads them from. Each comes with its licence file.
#
#   bash scripts/fetch-dictionaries.sh            # the default set
#   bash scripts/fetch-dictionaries.sh hr th      # just these
#
# Sources:
#   hr, fa: github.com/wooorm/dictionaries (UTF-8 copies)
#     hr: Denis Lacković, LGPL/SISSL · fa: Lilak, Apache 2.0
#   sr (Cyrillic), sr-Latn, bs, th: github.com/LibreOffice/dictionaries
#     sr, sr-Latn: Milutin Smiljanić, LGPL 3+/MPL 2+/GPL 3+ (affix rules, so every
#       inflected form; replaces the old full-form Rakić lists, which missed most forms)
#     bs: GPL 2+/LGPL 2.1+/MPL 1.1+ · th: NECTEC/libthai word lists, LGPL
set -euo pipefail

DEST="${KPTN_DICTIONARIES:-$HOME/Library/Application Support/KPTN.SUB/Dictionaries}"
# Words the dictionaries are missing (dictionaries/README.md in the repository). Found
# before moving into $DEST, so the script also works when started by a relative path.
REPO_EXTRAS="$(cd "$(dirname "$0")/.." && pwd)/dictionaries"
WOOORM="https://raw.githubusercontent.com/wooorm/dictionaries/main/dictionaries"
LIBRE="https://raw.githubusercontent.com/LibreOffice/dictionaries/master"

mkdir -p "$DEST"
cd "$DEST"

fetch() {  # url file
    local tmp="$2.part"
    if curl -fsSL --retry 3 -o "$tmp" "$1"; then mv "$tmp" "$2"; else rm -f "$tmp"; echo "  could not download $1" >&2; return 1; fi
}

get() {
    local code="$1"
    echo "• $code"
    case "$code" in
        hr|fa)
            fetch "$WOOORM/$code/index.aff" "$code.aff" &&
            fetch "$WOOORM/$code/index.dic" "$code.dic" &&
            fetch "$WOOORM/$code/license" "$code.license.txt" ;;
        sr|sr-Latn)
            fetch "$LIBRE/sr/$code.aff" "$code.aff" &&
            fetch "$LIBRE/sr/$code.dic" "$code.dic" &&
            fetch "$LIBRE/sr/README.txt" "$code.license.txt" ;;
        bs)
            fetch "$LIBRE/bs_BA/bs_BA.aff" bs.aff &&
            fetch "$LIBRE/bs_BA/bs_BA.dic" bs.dic &&
            fetch "$LIBRE/bs_BA/README.txt" bs.license.txt ;;
        th)
            fetch "$LIBRE/th_TH/th_TH.aff" th.aff &&
            fetch "$LIBRE/th_TH/th_TH.dic" th.dic &&
            fetch "$LIBRE/th_TH/README_th_TH.txt" th.license.txt ;;
        *)
            echo "  no source listed for $code" >&2; return 1 ;;
    esac
}


codes=("$@")
[ ${#codes[@]} -eq 0 ] && codes=(hr sr sr-Latn bs fa th)
failed=0
for c in "${codes[@]}"; do
    get "$c" || failed=1
    if [ -f "$REPO_EXTRAS/$c.extra.dic" ]; then cp "$REPO_EXTRAS/$c.extra.dic" .; echo "  + $c.extra.dic"; fi
done

echo
ls -la "$DEST"
echo
echo "Dictionaries are in: $DEST"
echo "In KPTN.SUB choose Edit ▸ Reload Dictionaries (or restart the app)."
exit $failed
