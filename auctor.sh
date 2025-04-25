#!/usr/bin/env bash
#---------------------------------------------------------
#  auctor.sh – rename PDF → surname-year.pdf
#  author :  Nivyan Lakhani
#---------------------------------------------------------
#  Requires: exiftool, pdftotext, curl, jq, realpath
#---------------------------------------------------------

# ── Locale fix ───────────────────────────────────────────
# Force byte-wise collation so grep/sed ranges like [A-Z] are safe
export LC_ALL=C
export LANG=C

# ── Configuration ────────────────────────────────────────
set -u                          # treat unset vars as error
# set -e                        # (optional) exit on first error

# ── Globals ──────────────────────────────────────────────
DRY_RUN=false
CONFIRM=true
VERBOSE=false
LOG_FILE=""
LOG_FH=""

RENAMED_COUNT=0
SKIPPED_COUNT=0
EXISTS_COUNT=0
DRY_PROPOSALS_COUNT=0
declare -a PDF_FILES_TODO=()

# ── Logging helpers ──────────────────────────────────────
log_msg() { echo "[$(date +'%T')] $*"; }
info()    { log_msg "INFO:"  "$*"; }
warn()    { log_msg "WARN:"  "$*" >&2; }
error()   { log_msg "ERROR:" "$*" >&2; }
debug()   { [[ "$VERBOSE" == "true" ]] && log_msg "DEBUG:" "$*" >&2; }

# ── Dependency check ─────────────────────────────────────
check_dependencies() {
    local missing=""
    for t in exiftool pdftotext curl jq realpath grep sed tr awk find mv dirname basename date; do
        command -v "$t" >/dev/null 2>&1 || missing+=" $t"
    done
    if [[ -n "$missing" ]]; then
        error "Missing tool(s):$missing"
        exit 2
    fi
}

# ── Small helpers ────────────────────────────────────────
ascii_clean() {
    local s="$1"
    [[ -z "$s" ]] && return
    local c
    c=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_-' '-')
    echo "$c" | sed -E 's/[-_]{2,}/-/g; s/^[-_]+|[-_]+$//g'
}

extract_year() { echo "$1" | grep -oE -m1 '\b(19[89][0-9]|20[0-9]{2})\b' || echo ""; }

surname_from() {
    local a="$1"
    [[ -z "$a" ]] && return
    local first="${a%%[,;&]*}"                # split on common delimiters
    local last
    last=$(echo "$first" | awk '{print $NF}')
    ascii_clean "$last"
}

is_likely_junk_surname() {
    local s="$1"; local l=${#s}
    [[ -z "$s" || $l -lt 2 ]] && { echo true; return; }
    local d; d=$(echo "$s" | tr -cd '0-9' | wc -c)
    [[ $l -gt 0 && $(awk "BEGIN{print ($d/$l)>0.6}") == 1 ]] && { echo true; return; }
    echo "$s" | grep -qiE '(publisher|arbortext|adobe|acrobat|microsoft|word|creator|tex|latex|elsevier|springer|wiley|taylor|francis|ieee|acm|service|ltd|inc|corp|university|journal|conference)' && { echo true; return; }
    [[ "$s" =~ ^[^a-z] ]] && { echo true; return; }
    echo false
}

firstpage_text() { pdftotext -f1 -l1 -enc UTF-8 "$1" - 2>/dev/null || echo ""; }

doi_in() { echo "$1" | grep -oEim1 '\b10\.[0-9]{4,9}/[-._;()/:A-Z0-9]+\b' || echo ""; }

query_crossref() {
    local doi="$1"
    [[ -z "$doi" || ! "$doi" =~ ^10\. ]] && { echo ""; return; }

    local json
    json=$(curl -sS --connect-timeout 7 --max-time 15 -L \
            -H 'Accept: application/json' "https://api.crossref.org/works/${doi}")
    [[ -z "$json" ]] && { echo ""; return; }

    echo "$json" | jq -r '
        .message as $m |
        (
            ($m.author[0].family) //
            ($m.author[0].name | split(" ") | last) //
            ""
        ) as $sn |
        (
            ($m."published-print"."date-parts"[0][0]) //
            ($m."published-online"."date-parts"[0][0]) //
            ($m.issued."date-parts"[0][0]) //
            ($m.created."date-parts"[0][0]) //
            ""
        ) as $yr | "\($sn) \($yr)"'
}

# ── Main name-proposal routine ───────────────────────────
propose_name() {
    local pdf="$1"
    debug "Proposing name for: $pdf"

    # 1) metadata ----------------------------------------------------------
    local exif_json
    # drop -G0 so keys come without namespace prefixes
    exif_json=$(exiftool -j -n -Author -Creator -CreateDate -ModifyDate -Identifier -DOI "$pdf" 2>/dev/null)

    local meta_author_raw meta_creator_raw meta_year doi=""
    if [[ -n "$exif_json" ]]; then
        meta_author_raw=$( echo "$exif_json" | jq -r '.[0].Author   // ""')
        meta_creator_raw=$(echo "$exif_json" | jq -r '.[0].Creator  // ""')
        local cdate mdate
        cdate=$(echo "$exif_json" | jq -r '.[0].CreateDate // ""')
        mdate=$(echo "$exif_json" | jq -r '.[0].ModifyDate // ""')
        meta_year=$(extract_year "$cdate")
        [[ -z "$meta_year" ]] && meta_year=$(extract_year "$mdate")

        # DOI from metadata if not printed on page 1
        doi=$(echo "$exif_json" | jq -r '.[0].Identifier // .[0].DOI // ""' | \
              grep -oE '10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+' || true)

        debug "Metadata raw: Author='$meta_author_raw', Creator='$meta_creator_raw', Year='$meta_year', DOI='$doi'"
    fi

    # 2) text on first page -----------------------------------------------
    local txt; txt=$(firstpage_text "$pdf")
    local text_year="" etal_author_raw=""
    if [[ -n "$txt" ]]; then
        [[ -z "$doi" ]] && doi=$(doi_in "$txt")
        text_year=$(extract_year "$txt")

        # try © 20xx fallback
        if [[ -z "$text_year" ]]; then
            local copy
            copy=$(echo "$txt" | grep -oEi -m1 '(©|\(c\)|copyright)[[:space:]]*[0-9]{4}')
            [[ -n "$copy" ]] && text_year=$(echo "$copy" | grep -oE '[0-9]{4}')
        fi

        etal_author_raw=$(echo "$txt" | grep -oEi -m1 \
            '\b([A-Z][-A-Za-z'\'']{2,})[[:space:]]+(et[[:space:]]*al\.?|and[[:space:]]+others)\b')
    fi

    # 3) CrossRef ----------------------------------------------------------
    local cr_auth_raw="" cr_year=""
    if [[ -n "$doi" ]]; then
        debug "Found DOI: $doi – querying CrossRef"
        read -r cr_auth_raw cr_year <<<"$(query_crossref "$doi")"
    fi

    # 4) choose best surname ----------------------------------------------
    local pick
    declare -A candidate=(
        [cr]=$(surname_from "$cr_auth_raw")
        [meta]=$(surname_from "$meta_author_raw")
        [etal]=$(surname_from "$etal_author_raw")
        [creator]=$(surname_from "$meta_creator_raw")
    )

    for tag in cr meta etal creator; do
        pick="${candidate[$tag]}"
        [[ -n "$pick" && $(is_likely_junk_surname "$pick") == false ]] && {
            final_surname="$pick"; break;
        }
    done
    [[ -z "${final_surname:-}" ]] && { debug "No valid surname."; echo ""; return; }

    # 5) choose best year --------------------------------------------------
    local final_year=""
    for y in "$cr_year" "$meta_year" "$text_year" "$(extract_year "$(basename "$pdf")")"; do
        [[ -n "$y" ]] && { final_year="$y"; break; }
    done
    [[ -z "$final_year" ]] && { debug "No valid year."; echo ""; return; }

    echo "${final_surname}-${final_year}.pdf"
}

# ── Renaming wrapper ─────────────────────────────────────
rename_file() {
    local pdf="$1" orig; orig=$(basename "$pdf")
    local prop; prop=$(propose_name "$pdf") || true
    [[ -z "$prop" || "$prop" == "$orig" ]] && return 1

    local tgt="${pdf%/*}/$prop"
    if [[ -e "$tgt" && $(realpath "$tgt") != $(realpath "$pdf") ]]; then
        warn "Collision: $prop exists. Skipping."; return 2
    fi

    printf "%s -> %s\n" "$orig" "$prop"
    [[ "$DRY_RUN" == true ]] && return 3
    [[ "$CONFIRM" == true ]] && { read -rp "Rename? [y/N] " ans; [[ $ans != [Yy]* ]] && return 1; }

    mv -f -- "$pdf" "$tgt" && {
        [[ -n "$LOG_FH" ]] && echo "$orig -> $prop" >>"$LOG_FH"
        return 0
    }
    warn "mv failed."; return 1
}

# ── CLI parsing ───────────────────────────────────────────
usage() {
cat <<EOF
Usage: bash auctor.sh [options] <pdf|dir> ...

Options
  -n, --dry-run     show what would be done, don't rename
  -y, --yes         don't ask, just rename
  -v, --verbose     verbose / debug output
  --log <file>      append rename log to <file>
  -h, --help        this help
EOF
}

declare -a INPUT_PATHS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run) DRY_RUN=true ;;
        -y|--yes)     CONFIRM=false ;;
        -v|--verbose) VERBOSE=true ;;
        --log)        LOG_FILE="$2"; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           error "Unknown option: $1"; usage; exit 1 ;;
        *)            INPUT_PATHS+=("$1") ;;
    esac
    shift
done
[[ ${#INPUT_PATHS[@]} -eq 0 ]] && { usage; exit 1; }

check_dependencies

# ── collect pdfs ──────────────────────────────────────────
find_pdfs() {
    local p; p=$(realpath -m "$1")
    [[ -d $p ]] && find "$p" -type f -iname '*.pdf' -print0 |
                  while IFS= read -r -d '' f; do PDF_FILES_TODO+=("$f"); done
    [[ -f $p && $p == *.pdf ]] && PDF_FILES_TODO+=("$p")
}
for a in "${INPUT_PATHS[@]}"; do find_pdfs "$a"; done
[[ ${#PDF_FILES_TODO[@]} -eq 0 ]] && { error "No PDFs."; exit 1; }

# ── log file ──────────────────────────────────────────────
if [[ -n "$LOG_FILE" ]]; then
    LOG_FH=$(realpath -m "$LOG_FILE")
    { echo "# $(date)   dry=$DRY_RUN verbose=$VERBOSE"; } >>"$LOG_FH" || {
        warn "can't write log '$LOG_FILE'"; LOG_FH=""; }
fi

# ── processing loop ───────────────────────────────────────
info "Processing ${#PDF_FILES_TODO[@]} PDF(s)…"
i=0
for f in "${PDF_FILES_TODO[@]}"; do
    ((i++))
    echo -e "\n[$i/${#PDF_FILES_TODO[@]}] $f"
    rename_file "$f"
    case $? in
        0) ((RENAMED_COUNT++)) ;;
        1) ((SKIPPED_COUNT++)) ;;
        2) ((EXISTS_COUNT++)) ;;
        3) ((DRY_PROPOSALS_COUNT++)) ;;
    esac
done

# ── summary ───────────────────────────────────────────────
echo -e "\n── Summary ──"
if $DRY_RUN; then
    echo "Proposed renames: $DRY_PROPOSALS_COUNT"
else
    echo "Renamed:  $RENAMED_COUNT"
fi
echo "Skipped :  $((SKIPPED_COUNT+EXISTS_COUNT))"
[[ $EXISTS_COUNT -gt 0 ]] && echo "Collisions: $EXISTS_COUNT"
[[ -n "$LOG_FH" ]] && echo "Log: $LOG_FH"

exit $(( RENAMED_COUNT + DRY_PROPOSALS_COUNT > 0 ? 0 : 1 ))
