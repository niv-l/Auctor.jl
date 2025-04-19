#!/bin/bash
# auctor.sh – rename PDF → surname-year.pdf
# author: Nivyan Lakhani
#
# Requires external tools: exiftool, pdftotext, curl, jq, realpath

# --- Configuration ---
set -u # Treat unset variables as an error
# set -e # Exit immediately if a command exits with a non-zero status (use cautiously or trap errors)

# --- Globals ---
DRY_RUN=false
CONFIRM=true
VERBOSE=false
LOG_FILE=""
LOG_FH="" # File handle placeholder

RENAMED_COUNT=0
SKIPPED_COUNT=0
EXISTS_COUNT=0
DRY_PROPOSALS_COUNT=0
declare -a PDF_FILES_TODO=() # Use an array for robustness

# --- Logging Functions ---
log_msg() { echo "[$(date +'%T')] $*"; }
info() { log_msg "INFO:" "$*"; }
warn() { log_msg "WARN:" "$*" >&2; }
error() { log_msg "ERROR:" "$*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && log_msg "DEBUG:" "$*" >&2; }

# --- Helper Functions ---

# Check for required external tools
check_dependencies() {
    local missing=""
    for tool in exiftool pdftotext curl jq realpath grep sed tr awk find mv dirname basename date; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [[ -n "$missing" ]]; then
        error "Required external tool(s) not found in PATH:$missing"
        error "Please install them and ensure they are accessible."
        exit 2
    fi
    debug "All dependencies found."
}

# NFD‑normalize `s`, drop diacritics, keep ASCII a–z,0–9,_,-, lowercase.
# Removes leading/trailing hyphens/underscores and collapses multiples.
# Note: Shell version is simpler, no true NFD normalization.
ascii_clean() {
    local s="$1"
    [[ -z "$s" ]] && return # Handle empty string
    local cleaned
    # Convert to lowercase, keep only alphanumeric and hyphen/underscore, replace others with space
    cleaned=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_-' '-')
    # Collapse multiple hyphens/underscores to single hyphen, remove leading/trailing
    cleaned=$(echo "$cleaned" | sed -E 's/[-_]{2,}/-/g; s/^[_-]+|[_-]+$//g')
    echo "$cleaned"
}

# Extract year (1980-2099)
extract_year() {
    local s="$1"
    echo "$s" | grep -oE -m 1 '\b(19[89][0-9]|20[0-9]{2})\b' || echo ""
}

# Take potential author string, find first author block, return cleaned surname.
surname_from() {
    local author_string="$1"
    [[ -z "$author_string" ]] && return
    # Split by common delimiters (comma, semicolon, 'and', '&') get first part
    local first_author_block
    first_author_block=$(echo "$author_string" | sed -E 's/\s*(,|;| and |&).*//I')
    # Get the last word of the first block
    local surname
    # Use awk to print the last field (word)
    surname=$(echo "$first_author_block" | awk '{print $NF}')
    ascii_clean "$surname"
}

# Heuristic check if a string is unlikely to be a real surname
is_likely_junk_surname() {
    local s="$1"
    local s_len=${#s}
    local digit_count

    [[ -z "$s" ]] && echo "true" && return
    [[ "$s_len" -lt 2 ]] && echo "true" && return # Too short

    # Count digits
    digit_count=$(echo "$s" | tr -cd '0-9' | wc -c)
    # Check digit ratio (avoid division by zero)
    if [[ "$s_len" -gt 0 ]] && awk "BEGIN {exit !($digit_count / $s_len > 0.6)}"; then
         echo "true" && return # Mostly digits
    fi

    # Contains common junk terms (case-insensitive) - simplified list
    if echo "$s" | grep -qEi '(publisher|publishing|arbortext|adobe|acrobat|microsoft|word|writer|creator|incopy|tex|latex|elsevier|springer|wiley|taylor|francis|ieee|acm|[0-9]+\.[0-9]+|service|ltd|inc|gmbh|corp|university|institute|journal|conference|proceedings)'; then
        echo "true" && return
    fi

    # Starts with non-letter (after cleaning, means starts with digit or hyphen)
    [[ "$s" =~ ^[^a-z] ]] && echo "true" && return

    echo "false"
}

# Extract first page text
firstpage_text() {
    local pdf="$1"
    # Use -enc UTF-8 for potentially better unicode handling, ignore stderr
    pdftotext -f 1 -l 1 -enc UTF-8 "$pdf" - 2>/dev/null || echo ""
}

# Extract DOI
doi_in() {
    local txt="$1"
    # Case-insensitive search, match only once
    echo "$txt" | grep -oEim 1 '\b10\.[0-9]{4,9}/[-._;()/:A-Z0-9]+\b' || echo ""
}

# Query CrossRef API
# Returns: "surname year" (space separated) or "" on error
query_crossref() {
    local doi="$1"
    local surname=""
    local year=""

    [[ -z "$doi" || ! "$doi" =~ ^10\. ]] && echo "" && return

    local api_url="https://api.crossref.org/works/${doi}"
    debug "Querying CrossRef: $api_url"

    # Added -L to follow redirects, increased timeouts
    local raw_json
    raw_json=$(curl -sS --connect-timeout 7 --max-time 15 -L -H 'Accept: application/json' "$api_url")
    local curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 || -z "$raw_json" ]]; then
        debug "CrossRef query for DOI $doi failed (curl exit: $curl_exit_code) or returned empty."
        echo "" && return
    fi

    # Use jq to parse JSON robustly
    # Extract surname: prefer family, fallback to name (last word), fallback to null
    # Extract year: prefer published-print, then online, issued, created
    local result
    result=$(echo "$raw_json" | jq -r '
        .message as $msg |
        if $msg then
            (
                ($msg.author | select(type=="array" and length > 0) | .[0].family) //
                ($msg.author | select(type=="array" and length > 0) | .[0].name | select(type=="string") | split(" ") | last) //
                ""
            ) as $surname |
            (
                ($msg."published-print"."date-parts"[0][0]) //
                ($msg."published-online"."date-parts"[0][0]) //
                ($msg.issued."date-parts"[0][0]) //
                ($msg.created."date-parts"[0][0]) //
                null | select(. != null) | tostring
            ) as $year_str |
            "\($surname) \($year_str)"
        else
            ""
        end
    ')
    local jq_exit_code=$?

    if [[ $jq_exit_code -ne 0 ]]; then
         debug "JSON parse error (jq exit: $jq_exit_code) for DOI $doi response."
         echo "" && return
    fi

    # Separate surname and year, extract year digits if found
    read -r cr_auth_raw cr_year_raw <<<"$result" # Use read for safer parsing
    local cr_year
    cr_year=$(extract_year "$cr_year_raw") # Validate/extract year format

    debug "CrossRef raw result: Author='$cr_auth_raw', Year Raw='$cr_year_raw', Year Clean='$cr_year'"
    # Return raw surname and cleaned year
    echo "$cr_auth_raw $cr_year"
}


# Gather info and propose name: "surname-year.pdf" or ""
propose_name() {
    local pdf="$1"
    debug "Proposing name for: $pdf"

    # --- 1. Gather Data ---
    local meta_author_raw="" meta_creator_raw="" meta_year=""
    local exif_json
    # -G0 option prints tag names without group prefix, -n prints -- for empty tags
    exif_json=$(exiftool -j -n -Author -Creator -CreateDate -ModifyDate -G0 "$pdf" 2>/dev/null)
    if [[ -n "$exif_json" ]]; then
        # Extract first element if array, handle missing fields with // ""
        meta_author_raw=$(echo "$exif_json" | jq -r '.[0].Author // ""')
        meta_creator_raw=$(echo "$exif_json" | jq -r '.[0].Creator // ""')
        local create_date; create_date=$(echo "$exif_json" | jq -r '.[0].CreateDate // ""')
        local modify_date; modify_date=$(echo "$exif_json" | jq -r '.[0].ModifyDate // ""')
        meta_year=$(extract_year "$create_date")
        [[ -z "$meta_year" ]] && meta_year=$(extract_year "$modify_date")
        debug "Metadata raw: Author='$meta_author_raw', Creator='$meta_creator_raw', Year='$meta_year'"
    else
        debug "Could not get metadata using exiftool for '$pdf'."
    fi

    local txt; txt=$(firstpage_text "$pdf")
    local doi="" text_year="" etal_author_raw=""
    if [[ -n "$txt" ]]; then
        doi=$(doi_in "$txt")
        text_year=$(extract_year "$txt")
        # Fallback: Check near copyright symbol
        if [[ -z "$text_year" ]]; then
            local copy_match
            copy_match=$(echo "$txt" | grep -oEi -m 1 '(©|\(c\)|copyright)\s*([0-9]{4})\b')
            if [[ -n "$copy_match" ]]; then
                text_year=$(echo "$copy_match" | grep -oE '[0-9]{4}')
                debug "Found year '$text_year' from copyright notice in text."
            fi
        fi
        # Look for "Surname et al." pattern (simple capitalised word before et al)
        etal_author_raw=$(echo "$txt" | grep -oEi -m 1 "\b([A-Z][A-Za-z\\-']{2,})\\s+(et\\s*al\\.?|and\\s+others)\b")
        if [[ -n "$etal_author_raw" ]]; then
            # Remove the " et al." part
             etal_author_raw=$(echo "$etal_author_raw" | sed -E 's/\s+(et al|and others).*//I')
             debug "Found potential 'et al.' author '$etal_author_raw' in text."
        fi
    else
        debug "Could not extract text from first page of '$pdf'."
    fi

    local cr_auth_raw="" cr_year=""
    if [[ -n "$doi" ]]; then
        debug "Found DOI: $doi in '$pdf', querying CrossRef..."
        read -r cr_auth_raw cr_year <<<$(query_crossref "$doi") # Read space-separated result
        debug "CrossRef returned: Author='$cr_auth_raw', Year='$cr_year' for DOI $doi"
    else
        debug "No DOI found in first page text of '$pdf'."
    fi

    # --- 2. Process and Validate Candidates ---
    local meta_surname; meta_surname=$(surname_from "$meta_author_raw")
    if [[ -n "$meta_surname" ]] && [[ $(is_likely_junk_surname "$meta_surname") == "true" ]]; then
        debug "Discarding likely junk metadata Author surname: '$meta_surname' (raw: '$meta_author_raw')"
        meta_surname=""
    elif [[ -n "$meta_surname" ]]; then
        debug "Valid metadata Author surname found: '$meta_surname'"
    fi

    local creator_surname; creator_surname=$(surname_from "$meta_creator_raw")
    if [[ -n "$creator_surname" ]] && [[ $(is_likely_junk_surname "$creator_surname") == "true" ]]; then
        debug "Discarding likely junk metadata Creator surname: '$creator_surname' (raw: '$meta_creator_raw')"
        creator_surname=""
    elif [[ -n "$creator_surname" ]]; then
        debug "Valid metadata Creator surname found: '$creator_surname'"
    fi

    local etal_surname; etal_surname=$(surname_from "$etal_author_raw")
    if [[ -n "$etal_surname" ]] && [[ $(is_likely_junk_surname "$etal_surname") == "true" ]]; then
        debug "Discarding likely junk 'et al.' surname: '$etal_surname' (raw: '$etal_author_raw')"
        etal_surname=""
    elif [[ -n "$etal_surname" ]]; then
        debug "Valid 'et al.' text surname found: '$etal_surname'"
    fi

    local cr_surname; cr_surname=$(surname_from "$cr_auth_raw")
    if [[ -n "$cr_surname" ]] && [[ $(is_likely_junk_surname "$cr_surname") == "true" ]]; then
        debug "Discarding likely junk CrossRef surname: '$cr_surname' (raw: '$cr_auth_raw')"
        cr_surname=""
    elif [[ -n "$cr_surname" ]]; then
        debug "Valid CrossRef surname found: '$cr_surname'"
    fi

    # --- 3. Prioritize and Select Final Values ---
    local final_surname=""
    # Priority: CrossRef > Metadata Author > Text 'et al.' > Metadata Creator
    if [[ -n "$cr_surname" ]]; then final_surname="$cr_surname"; debug "Using CrossRef surname: '$final_surname'";
    elif [[ -n "$meta_surname" ]]; then final_surname="$meta_surname"; debug "Using metadata Author surname: '$final_surname'";
    elif [[ -n "$etal_surname" ]]; then final_surname="$etal_surname"; debug "Using 'et al.' text surname: '$final_surname'";
    elif [[ -n "$creator_surname" ]]; then final_surname="$creator_surname"; debug "Using metadata Creator surname as last resort: '$final_surname'";
    else debug "No valid surname found after checks for '$pdf'."; fi

    local final_year=""
    # Priority: CrossRef > Metadata Date > Text Year > Filename Year
    if [[ -n "$cr_year" ]]; then final_year="$cr_year"; debug "Using CrossRef year: '$final_year'";
    elif [[ -n "$meta_year" ]]; then final_year="$meta_year"; debug "Using metadata year: '$final_year'";
    elif [[ -n "$text_year" ]]; then final_year="$text_year"; debug "Using text-extracted year: '$final_year'";
    else
        local fn_year; fn_year=$(extract_year "$(basename "$pdf")")
        if [[ -n "$fn_year" ]]; then
            final_year="$fn_year"
            debug "Using filename year as last resort: '$final_year'"
        else
             debug "No valid year found after checks for '$pdf'."
        fi
    fi

    # --- 4. Final Validation and Return ---
    if [[ -z "$final_surname" || -z "$final_year" ]]; then
        warn "Could not determine valid author/year for '$pdf'. Skipping."
        echo "" # Return empty string for failure
        return
    fi

    # Final length check
    if [[ ${#final_surname} -lt 2 ]]; then
        warn "Final surname '$final_surname' too short for '$pdf'. Skipping."
        echo "" # Return empty string for failure
        return
    fi

    echo "${final_surname}-${final_year}.pdf"
}

# --- Rename Action ---
# Returns status code: 0=done, 1=skip, 2=exists, 3=dry
rename_file() {
    local pdf="$1"
    local orig; orig=$(basename "$pdf")
    local status=1 # Default to skip

    local prop_name; prop_name=$(propose_name "$pdf")

    if [[ -z "$prop_name" ]]; then
        return 1 # Skip if proposal failed
    fi

    if [[ "$prop_name" == "$orig" ]]; then
        info "File '$orig' already named correctly. Skipping."
        return 1 # Skip if already correct
    fi

    local tgt_dir; tgt_dir=$(dirname "$pdf")
    local tgt_path="${tgt_dir}/${prop_name}"
    local original_proposal="$prop_name" # For logging

    # Handle potential filename collision robustly
    if [[ -e "$tgt_path" ]]; then
        debug "Target path '$tgt_path' exists. Checking if it's the same file..."
        local pdf_real; pdf_real=$(realpath "$pdf" 2>/dev/null)
        local tgt_real; tgt_real=$(realpath "$tgt_path" 2>/dev/null)

        if [[ -n "$pdf_real" && -n "$tgt_real" && "$pdf_real" != "$tgt_real" ]]; then
            # Collision with a DIFFERENT file/directory
            debug "Collision with a different file/directory at '$tgt_path'."
            local base; base="${prop_name%.pdf}" # Get base name without extension
            local ext=".pdf"
            local found_alt=false
            for c in {a..z}; do
                local alt_name="${base}${c}${ext}"
                local alt_path="${tgt_dir}/${alt_name}"
                if [[ ! -e "$alt_path" ]]; then
                    tgt_path="$alt_path"
                    prop_name="$alt_name"
                    found_alt=true
                    info "Collision detected for '$orig' -> '$original_proposal'. Using alternative name: '$prop_name'"
                    break
                fi
            done
            if [[ "$found_alt" == "false" ]]; then
                warn "Collision: Target '$original_proposal' and alternatives a-z already exist for '$orig'. Skipping."
                return 2 # Indicate collision prevented action
            fi
        elif [[ -z "$pdf_real" || -z "$tgt_real" ]]; then
             warn "Could not get realpath for '$pdf' or '$tgt_path' to check collision accurately. Skipping."
             return 1 # Skip due to error
        else
             # Target exists but IS the original file (e.g. case change on case-insensitive FS)
             debug "Target path '$tgt_path' is the same file as '$pdf'. Rename will proceed."
        fi
    fi

    printf "%s -> %s\n" "$orig" "$prop_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        return 3 # Dry run status
    fi

    if [[ "$CONFIRM" == "true" ]]; then
        read -p "Apply rename? [y/N]: " -r response
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
        if [[ "$response" != "y" && "$response" != "yes" ]]; then
            echo "Skipped by user."
            return 1 # Skip
        fi
    fi

    # Use -f to handle case where target is the same file (e.g. case change)
    if mv -f "$pdf" "$tgt_path"; then
        # Log original basename -> new basename
        [[ -n "$LOG_FH" ]] && echo "$orig -> $prop_name" >> "$LOG_FH"
        echo "Renamed."
        return 0 # Done
    else
        error "Failed to rename '$orig' to '$prop_name'. Exit code: $?"
        # Check if the target now exists (race condition or other mv failure)
        if [[ -e "$tgt_path" ]]; then
            error "Rename failed, possibly due to race condition or filesystem issue. Target '$prop_name' may now exist."
             return 2 # Treat as collision/exists if mv failed but target is present
        fi
         return 1 # Treat other rename errors as skip
    fi
}

# --- Argument Parsing ---
usage() {
    cat << EOF
Usage: bash auctor.sh [options] <pdf | dir> ...

Rename PDFs to "surname-year.pdf". Extracts info from metadata,
first page text, and CrossRef (via DOI if found), prioritizing
higher quality sources (CrossRef > Author Meta > Text Heuristic > Creator Meta).
Handles filename collisions by appending 'a', 'b', etc.

Requires external tools: exiftool, pdftotext, curl, jq, realpath

Options:
  -n, --dry-run    Preview rename operations only.
  -y, --yes        Do not ask for confirmation, rename directly.
  -v, --verbose    Show debug information for extraction steps.
  -h, --help       Show this help message and exit.
  --log <file>   Log successful renames (original -> new) to <file>.
EOF
}

# Parse arguments
declare -a INPUT_PATHS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -y|--yes) CONFIRM=false; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --log)
            if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                 error "--log option requires a filename argument."
                 exit 1
            fi
            LOG_FILE="$2"
            shift 2
            ;;
        -*) error "Unknown option: $1. Use -h or --help for usage."; exit 1 ;;
        *) INPUT_PATHS+=("$1"); shift ;;
    esac
done

# --- Main Logic ---

# Configure logging level (just enables/disables debug output)
debug "Verbose logging enabled." # Will only show if -v was passed

if [[ ${#INPUT_PATHS[@]} -eq 0 ]]; then
    error "Usage: bash auctor.sh [options] <pdf | dir> ..."
    error "Use -h or --help for more information."
    exit 1
fi

# Check dependencies early
check_dependencies

# --- Gather PDFs ---
info "Scanning for PDF files..."
shopt -s globstar nullglob # Enable ** and avoid errors if no match

find_pdfs() {
    local path_arg="$1"
    local path
    # Cannot expanduser easily in pure bash, rely on shell expansion before script runs or absolute paths
    path=$(realpath -m "$path_arg" 2>/dev/null) # -m allows non-existent paths for now

    if [[ ! -e "$path" ]]; then
        warn "Input path not found: $path_arg. Skipping."
        return
    fi

    if [[ -d "$path" ]]; then
        debug "Scanning directory: $path"
        # Use find for robust recursive search, handle filenames safely with print0/read
        while IFS= read -r -d $'\0' file; do
             if [[ -f "$file" && -r "$file" ]]; then # Check if regular, readable file
                 debug "Found PDF: $file"
                 PDF_FILES_TODO+=("$file")
             else
                 warn "Skipping likely invalid or unreadable file: $file"
             fi
        done < <(find "$path" -type f -iname "*.pdf" -print0)
    elif [[ -f "$path" && "${path,,}" == *.pdf ]]; then # Case-insensitive check
         if [[ -r "$path" ]]; then
             debug "Adding specified PDF: $path"
             PDF_FILES_TODO+=("$path")
         else
             warn "Skipping likely invalid or unreadable file: $path"
         fi
    else
        warn "Skipping non-PDF file or non-directory: $path_arg"
    fi
}

for arg in "${INPUT_PATHS[@]}"; do
    find_pdfs "$arg"
done

if [[ ${#PDF_FILES_TODO[@]} -eq 0 ]]; then
    error "No valid PDF files found in the specified paths."
    exit 1
fi

# --- Setup Logging File ---
if [[ -n "$LOG_FILE" ]]; then
    # Cannot expand user robustly here either, rely on shell doing it before script start
    LOG_FILE_ABS=$(realpath -m "$LOG_FILE" 2>/dev/null) # Get absolute path if possible
     if [[ -z "$LOG_FILE_ABS" ]]; then
          warn "Could not determine absolute path for log file '$LOG_FILE'. Using relative path."
          LOG_FILE_ABS="$LOG_FILE"
     fi
     # Attempt to create/append to the log file
     {
         echo "# Auctor.sh Log - Started: $(date)"
         echo "# Options: dry=$DRY_RUN, confirm=$CONFIRM, verbose=$VERBOSE"
     } >> "$LOG_FILE_ABS" 2>/dev/null

     if [[ $? -eq 0 ]]; then
         LOG_FH="$LOG_FILE_ABS" # Store path to use for logging
         info "Logging renames to: $LOG_FH"
     else
         error "Could not open or write to log file '$LOG_FILE_ABS'. Logging disabled."
         LOG_FH=""
     fi
fi

# --- Process Files ---
total_files=${#PDF_FILES_TODO[@]}
echo # Newline before processing starts
info "Processing $total_files PDF file(s)..."

k=0
for f in "${PDF_FILES_TODO[@]}"; do
    k=$((k + 1))
    echo # Newline separator
    echo "---"
    printf "[%d/%d] Processing: %s\n" "$k" "$total_files" "$f"
    rename_file "$f"
    status=$? # Capture return status from rename_file

    case $status in
        0) RENAMED_COUNT=$((RENAMED_COUNT + 1)) ;;
        1) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
        2) EXISTS_COUNT=$((EXISTS_COUNT + 1)) ;;
        3) DRY_PROPOSALS_COUNT=$((DRY_PROPOSALS_COUNT + 1)) ;;
        *) warn "Unknown status $status returned from rename_file for '$f'. Counting as skipped." ; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
    esac
done

# --- Final Summary ---
if [[ -n "$LOG_FH" ]]; then
    {
        echo "# Finished: $(date)"
        echo "# Renamed: $RENAMED_COUNT, Skipped: $SKIPPED_COUNT, Collisions: $EXISTS_COUNT, Dry Proposals: $DRY_PROPOSALS_COUNT"
    } >> "$LOG_FH" 2>/dev/null || warn "Error writing final summary to log file '$LOG_FH'."
fi


echo # Newline
echo "--- Summary ---"
total_skipped_or_exists=$((SKIPPED_COUNT + EXISTS_COUNT))

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete."
    echo "Proposed renames for $DRY_PROPOSALS_COUNT files."
    echo "Skipped $total_skipped_or_exists files (no change needed, missing info, potential collision, or error)."
    [[ $EXISTS_COUNT -gt 0 ]] && echo "$EXISTS_COUNT potential collisions detected."
else
    echo "Renamed $RENAMED_COUNT files."
    echo "Skipped $total_skipped_or_exists files (no change, missing info, user skip, collision, or error)."
    [[ $EXISTS_COUNT -gt 0 ]] && echo "$EXISTS_COUNT collisions prevented renaming."
    [[ -n "$LOG_FH" ]] && echo "Log file: $LOG_FH"
fi

# Exit code: 0 if any files were renamed or proposed successfully, 1 otherwise.
if [[ $RENAMED_COUNT -gt 0 || $DRY_PROPOSALS_COUNT -gt 0 ]]; then
    exit 0
else
    exit 1
fi
