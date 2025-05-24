#!/usr/bin/env bash
#---------------------------------------------------------
#  auctor.sh – rename PDF → surname-year.pdf
#---------------------------------------------------------
#  Needs: exiftool pdftotext curl jq realpath grep sed tr awk find mv
#---------------------------------------------------------

################ 1.  Shell & locale #####################################
set -u                          # undefined variables are errors
export LC_ALL=C
export LANG=C

################ 2.  Globals ############################################
DRY_RUN=false CONFIRM=true VERBOSE=false
LOG_FH=""

RENAMED=0 SKIPPED=0 COLLISIONS=0 PROPOSED=0
declare -a PDF_LIST=()

################ 3.  Logging ############################################
log()   { printf '[%(%T)T] %s\n' -1 "$*"; }
debug() { $VERBOSE && log "DEBUG: $*"; }
info()  {          log "INFO : $*"; }
warn()  {          log "WARN : $*" >&2; }
err()   {          log "ERROR: $*" >&2; }

################ 4.  Dependency check ###################################
need() {
  local m=""
  for t in exiftool pdftotext curl jq realpath grep sed tr awk find mv \
           dirname basename date; do
    command -v "$t" &>/dev/null || m+=" $t"
  done
  [[ -n $m ]] && { err "Missing:$m"; exit 2; }
}

################ 5.  Helpers ############################################
ascii_clean() {
  tr '[:upper:]' '[:lower:]' <<<"${1:-}" \
  | tr -cs '[:alnum:]_-' '-' \
  | sed -E 's/[-_]{2,}/-/g;s/^[-_]+|[-_]+$//g'
}

year_of() { grep -o -m1 '\b\(19[89][0-9]\|20[0-9]\{2\}\)\b' <<<"$1" || true; }

surname_from() {
  local raw="${1:-}"; [[ -z $raw ]] && return
  ascii_clean "$(sed -E 's/[;,].*//;s/\s+and.*//' <<<"$raw" | awk '{print $NF}')"
}

first_page() { pdftotext -f1 -l1 -enc UTF-8 "$1" - 2>/dev/null || echo ""; }
doi_in()     { grep -oim1 '\b10\.[0-9]\{4,9\}/[-._;()/:A-Z0-9]\+\b' <<<"$1" || true; }

junk_surname() {                    ### FIX – tolerate zero args
  local s="${1:-}" ; local len=${#s}
  [[ -z $s || $len -lt 2 ]] && { echo true; return; }

  local dig; dig=$(tr -cd '0-9' <<<"$s" | wc -c)
  awk -v d=$dig -v l=$len 'BEGIN{exit !(d/l>0.6)}' && { echo true; return; }

  grep -qiE '(publisher|adobe|tex|elsevier|springer|wiley|ieee|acm|
              university|journal|conference|[0-9]+\.[0-9]+)' <<<"$s" &&
              { echo true; return; }

  [[ $s =~ ^[^a-z] ]] && { echo true; return; }
  echo false
}

crossref() {
  local doi="$1"; [[ ! $doi =~ ^10\. ]] && return
  local j; j=$(curl -sSL --max-time 15 -H 'Accept: application/json' \
            "https://api.crossref.org/works/$doi") || return
  jq -r '
    .message as $m |
    (
      ($m.author[0].family) //
      ($m.author[0].name|split(" ")|last) //
      ""
    ) as $sn |
    (
      ($m."published-print"."date-parts"[0][0]) //
      ($m."published-online"."date-parts"[0][0]) //
      ($m.issued."date-parts"[0][0]) //
      ($m.created."date-parts"[0][0]) //
      ""
    ) as $yr | "\($sn) \($yr)"
  ' <<<"$j"
}

################ 6.  Make proposal ######################################
propose_name() {
  local pdf="$1"

  # metadata -------------------------------------------------------------
  local ej; ej=$(exiftool -j -n -Author -Creator -CreateDate -ModifyDate \
                          -Identifier -DOI "$pdf" 2>/dev/null)
  local m_author m_creator m_year doi=""
  if [[ -n $ej ]]; then
    m_author=$( jq -r '.[0].Author  // ""' <<<"$ej" )
    m_creator=$(jq -r '.[0].Creator // ""' <<<"$ej" )
    local cd md
    cd=$(jq -r '.[0].CreateDate // ""' <<<"$ej")
    md=$(jq -r '.[0].ModifyDate // ""' <<<"$ej")
    m_year=$(year_of "$cd"); [[ -z $m_year ]] && m_year=$(year_of "$md")
    doi=$( jq -r '.[0].Identifier // .[0].DOI // ""' <<<"$ej" |
           grep -oE '10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+' || true )
  fi

  # first page -----------------------------------------------------------
  local txt txt_year="" etal=""
  txt=$(first_page "$pdf")
  if [[ -n $txt ]]; then
    [[ -z $doi ]] && doi=$(doi_in "$txt")
    txt_year=$(year_of "$txt")
    if [[ -z $txt_year ]]; then
      txt_year=$(grep -oi -m1 '\(copyright\|(c)\)[[:space:]]*[0-9]\{4\}' <<<"$txt" |
                 grep -o '[0-9]\{4\}' || true) # BRE for year extraction too

    fi
    etal=$(grep -oEi -m1 \
      "\b\([A-Z][-A-Za-z']\{2,\}\)[[:space:]][[:space:]]*\(et[[:space:]]*al\.?\|and[[:space:]][[:space:]]*others\)\b" \
      <<<"$txt" || true)
  fi

  # cross-ref ------------------------------------------------------------
  local cr_a="" cr_y=""
  [[ -n $doi ]] && read -r cr_a cr_y <<<"$(crossref "$doi")"

  # choose surname -------------------------------------------------------
  local surname=""
  for c in "$(surname_from "$cr_a")" "$(surname_from "$m_author")" \
           "$(surname_from "$etal")" "$(surname_from "$m_creator")"; do
    [[ -n $c && $(junk_surname "$c") == false ]] && { surname="$c"; break; }
  done
  [[ -z $surname ]] && return 1

  # choose year ----------------------------------------------------------
  local year=""
  for y in "$cr_y" "$m_year" "$txt_year" "$(year_of "$(basename "$pdf")")"; do
    [[ -n $y ]] && { year="$y"; break; }
  done
  [[ -z $year ]] && return 1

  echo "${surname}-${year}.pdf"
}

################ 7.  Rename wrapper #####################################
do_rename() {
  local pdf="$1" base=${1##*/}
  local prop; prop=$(propose_name "$pdf") || true
  [[ -z $prop || $prop == "$base" ]] && return 1

  local tgt="${pdf%/*}/$prop"
  if [[ -e $tgt && $(realpath "$tgt") != $(realpath "$pdf") ]]; then
    warn "collision: $prop"; return 2; fi

  printf '%s -> %s\n' "$base" "$prop"
  $DRY_RUN && return 3
  $CONFIRM && { read -rp "Rename? [y/N] " a; [[ $a != [Yy]* ]] && return 1; }

  mv -f -- "$pdf" "$tgt" &&
    { [[ -n $LOG_FH ]] && echo "$base -> $prop" >>"$LOG_FH"; return 0; }
  warn "mv failed"; return 1
}

################ 8.  CLI parsing ########################################
usage() {
cat <<EOF
Usage: auctor.sh [options] <pdf|dir> ...
  -n --dry-run   only show what would be done
  -y --yes       no questions asked
  -v --verbose   debug output
  --log FILE     append changes to FILE
  -h --help      this help
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--dry-run) DRY_RUN=true ;;
    -y|--yes)     CONFIRM=false ;;
    -v|--verbose) VERBOSE=true ;;
    --log)        LOG_FH=$2; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           err "bad option $1"; usage; exit 1 ;;
    *)            ARGS+=("$1") ;;
  esac; shift; done
[[ ${#ARGS[@]} -eq 0 ]] && { usage; exit 1; }

need

################ 9.  Collect PDFs #######################################
collect() {
  local p; p=$(realpath -m "$1")
  if [[ -d $p ]]; then
    while IFS= read -r -d '' f; do PDF_LIST+=("$f"); done \
      < <(find "$p" -type f -iname '*.pdf' -print0)
  elif [[ -f $p && $p == *.pdf ]]; then
    PDF_LIST+=("$p")
  fi
}
for a in "${ARGS[@]}"; do collect "$a"; done
[[ ${#PDF_LIST[@]} -eq 0 ]] && { err "No PDFs."; exit 1; }

################ 10.  Log file ##########################################
if [[ -n $LOG_FH ]]; then
  LOG_FH=$(realpath -m "$LOG_FH")
  { echo "# $(date) dry=$DRY_RUN verbose=$VERBOSE"; } >>"$LOG_FH" ||
    { warn "cannot write log"; LOG_FH=""; }
fi

################ 11.  Main loop #########################################
info "Processing ${#PDF_LIST[@]} PDF(s)"
i=0
for f in "${PDF_LIST[@]}"; do
  ((i++)); echo; echo "[$i/${#PDF_LIST[@]}] $f"
  do_rename "$f"
  case $? in
    0) ((RENAMED++));;
    1) ((SKIPPED++));;
    2) ((COLLISIONS++));;
    3) ((PROPOSED++));;
  esac
done

################ 12.  Summary ###########################################
echo -e "\n── Summary ──"
$DRY_RUN && echo "Proposed : $PROPOSED" || echo "Renamed : $RENAMED"
echo "Skipped  : $((SKIPPED+COLLISIONS))"
[[ $COLLISIONS -gt 0 ]] && echo "Collisions: $COLLISIONS"
[[ -n $LOG_FH ]] && echo "Log      : $LOG_FH"

exit $(( RENAMED + PROPOSED > 0 ? 0 : 1 ))
