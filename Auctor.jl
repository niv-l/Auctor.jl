#!/usr/bin/env julia
# Auctor.jl  –  rename PDF → surname‑year.pdf
#
# Requires external tools: exiftool, pdftotext, curl
# Julia deps: JSON (std‑lib: Unicode, Dates, Printf).
# If needed:  using Pkg; Pkg.add("JSON")

using JSON, Unicode, Dates, Printf
using Logging # Added for configure_logging

# ───────────────────────── helpers ────────────────────────────────────────

"""
    capture(cmd) :: String
Run `cmd`, return STDOUT, or "" on any error.
"""
function capture(cmd::Cmd)::String
    out, err = Pipe(), Pipe()
    try
        # Redirect stderr to null to avoid clutter unless debugging
        p = run(pipeline(cmd, stdout=out, stderr=devnull), wait=false)
        close(out.in)
        s_out = @async read(out, String)
        wait(p)
        close(out)
        # Check exit code explicitly
        return p.exitcode == 0 ? fetch(s_out) : ""
    catch e
        # Ensure pipe is closed on error, log the error if debugging is enabled
        @debug "Error capturing command `$cmd`: $e"
        try close(out; allowerror=true) catch; end
        return ""
    end
end


"""
    ascii_clean(s) :: String
NFD‑normalize `s`, drop diacritics, keep ASCII a–z,0–9,_,-, lowercase.
Removes leading/trailing hyphens/underscores and collapses multiples.
"""
function ascii_clean(s::AbstractString)::String
    isempty(s) && return ""
    # NFD normalize first to separate base characters and diacritics
    normalized_s = Unicode.normalize(s, :NFD)
    buf = IOBuffer()
    for c in normalized_s
        # Keep ASCII letters, digits, underscore, hyphen. Drop others (including diacritics).
        if isascii(c) && (isletter(c) || isdigit(c) || c == '_' || c == '-')
             write(buf, lowercase(c)) # Convert to lowercase directly
        end
    end
    # Process the cleaned string
    cleaned = String(take!(buf))
    # Collapse multiple hyphens/underscores to a single hyphen
    cleaned = replace(cleaned, r"[-_]{2,}" => "-")
    # Remove leading/trailing hyphens/underscores
    cleaned = replace(cleaned, r"^[_-]+|[_-]+$" => "")
    return cleaned
end


# More specific year regex
const YEAR_REGEX = r"\b(19[89]\d|20\d{2})\b"
extract_year(s::AbstractString)::String = (m = match(YEAR_REGEX, s)) === nothing ? "" : m.captures[1]

"""
    surname_from(author_string)
Take potential author string, find first author block, return cleaned surname.
Handles single string input.
"""
function surname_from(author_string::AbstractString)::String
    isempty(author_string) && return ""
    # Handle common separators including 'and' and '&', commas, semicolons
    # Split only by common delimiters, assuming the first part is the first author
    first_author_block = split(author_string, r"(\s*,\s*|\s*;\s*|\s+and\s+|\s*&\s*)", limit=2)[1]
    # Split the first block into words and take the last word as potential surname
    tokens = split(strip(first_author_block))
    isempty(tokens) ? "" : ascii_clean(last(tokens)) # Clean the potential surname
end

"""
    is_likely_junk_surname(s) :: Bool
Heuristic check if a string is unlikely to be a real surname (e.g., software name, number).
"""
function is_likely_junk_surname(s::AbstractString)::Bool
    isempty(s) && return true
    length(s) < 2 && return true # Too short is suspicious
    # Mostly digits indicates version numbers etc.
    # Avoid division by zero if length is zero (already checked by isempty)
    (count(isdigit, s) / length(s)) > 0.6 && return true
    # Contains common software/publisher terms (case-insensitive)
    # Added more terms like IEEE, ACM, etc.
    occursin(r"(publisher|publishing|arbortext|adobe|acrobat|microsoft|word|writer|creator|incopy|tex|latex|elsevier|springer|wiley|taylor|francis|ieee|acm|\d+\.\d+|service|ltd|inc|gmbh|corp|university|institute|journal|conference|proceedings)"i, s) && return true
    # Starts with non-letter (after cleaning, this means it starts with digit, _, or -)
    !isempty(s) && !isletter(first(s)) && return true
    return false
end


firstpage_text(pdf::AbstractString)::String = capture(`pdftotext -f 1 -l 1 "$pdf" -`) # Added quotes for safety

doi_in(txt::AbstractString)::String = (m = match(r"\b10\.\d{4,9}/[-._;()/:A-Z0-9]+\b"i, txt)) === nothing ? "" : m.match # case-insensitive DOI regex

"""
    crossref(doi) :: (surname, year)
Minimal CrossRef query, return first author surname and year if found.
"""
function crossref(doi::AbstractString)
    (isempty(doi) || !startswith(doi, "10.")) && return "", ""
    # Use "-H 'Accept: application/json'" for robustness. Increased timeouts slightly.
    # Added --location (-L) to follow redirects, common with DOIs.
    raw = capture(`curl -sS --connect-timeout 7 --max-time 15 -L -H 'Accept: application/json' "https://api.crossref.org/works/$(doi)"`)
    raw == "" && (@debug "CrossRef query for DOI $doi failed or returned empty."; return "", "")
    data = try JSON.parse(raw) catch e; @debug "JSON parse error for DOI $doi response: $e"; return "", "" end

    # Check if the 'message' field exists and is a dictionary
    msg = get(data, "message", nothing)
    !(msg isa Dict) && (@debug "CrossRef response for DOI $doi missing 'message' field or is not a Dict."; return "", "")

    # Extract author surname
    auth_raw = ""
    authors = get(msg, "author", nothing)
    if authors isa Vector && !isempty(authors) && authors[1] isa Dict
        first_author = authors[1]
        # Prefer 'family' name
        surname = get(first_author, "family", nothing)
        if !(surname isa AbstractString) || isempty(surname)
            # Fallback to 'name' if 'family' not present/empty
            name_field = get(first_author, "name", nothing)
            if name_field isa AbstractString && !isempty(name_field)
                # If 'name' field was used, it might contain full name, try to get last word
                if occursin(r"\s", name_field) # Check for space to indicate multiple words
                    auth_raw = split(name_field)[end]
                else
                    auth_raw = name_field # Assume single word is the surname/identifier
                end
            end
        else
            # 'family' field exists and is a non-empty string
             auth_raw = surname
        end
    end

    # Extract year using chained gets - prioritize print date, then online, issued, created
    year_val = nothing
    date_sources = ["published-print", "published-online", "issued", "created"]
    for source_key in date_sources
        source = get(msg, source_key, nothing)
        if source isa Dict
            dp = get(source, "date-parts", nothing)
            # Check date-parts structure robustness
            if dp isa Vector && !isempty(dp) && dp[1] isa Vector && !isempty(dp[1]) && dp[1][1] isa Integer
                year_val = dp[1][1]
                @debug "Found year $year_val from CrossRef source '$source_key' for DOI $doi"
                break # Found a year, stop checking other sources
            end
        end
    end

    yr = year_val === nothing ? "" : extract_year(string(year_val))

    # Return raw surname here, cleaning/validation happens later
    return auth_raw, yr
end


# ───────────────────── propose target name ────────────────────────────────

"""
    proposed_name(pdf) :: String|nothing
Gather info from metadata, text, and CrossRef, then prioritize to return
"surname-year.pdf" or `nothing` if reliable data is missing.
"""
function proposed_name(pdf::AbstractString)
    # --- 1. Gather Data from All Sources ---
    meta_author_raw, meta_creator_raw, meta_year = "", "", ""
    meta = capture(`exiftool -j -Author -Creator -CreateDate -ModifyDate "$pdf"`)
    if !isempty(meta)
        json_data = try JSON.parse(meta) catch e; @debug "JSON parse error for exiftool output for '$pdf': $e"; [] end
        if !isempty(json_data) && json_data[1] isa Dict
            m = json_data[1]

            author_val = get(m, "Author", "")
            creator_val = get(m, "Creator", "")

            if author_val isa Vector && !isempty(author_val) && first(author_val) isa AbstractString
                meta_author_raw = first(author_val)
                @debug "Extracted first author from metadata list: '$meta_author_raw'"
            elseif author_val isa AbstractString
                meta_author_raw = author_val
            else
                meta_author_raw = "" # Handle empty or non-string/vector cases
            end

            if creator_val isa Vector && !isempty(creator_val) && first(creator_val) isa AbstractString
                meta_creator_raw = first(creator_val)
                @debug "Extracted first creator from metadata list: '$meta_creator_raw'"
            elseif creator_val isa AbstractString
                meta_creator_raw = creator_val
            else
                meta_creator_raw = "" # Handle empty or non-string/vector cases
            end

            # Prioritize CreateDate over ModifyDate for year
            meta_year = extract_year(get(m, "CreateDate", get(m, "ModifyDate", "")))
            @debug "Metadata raw: Author='$meta_author_raw', Creator='$meta_creator_raw', Year='$meta_year'"
        end
    end

    txt = firstpage_text(pdf)
    doi = ""
    text_year = ""
    etal_author_raw = "" # Author surname guessed from text like "Author et al."
    if !isempty(txt)
        doi = doi_in(txt)
        text_year = extract_year(txt)
        # Fallback: Check near copyright symbol if year still missing
        if isempty(text_year)
            # Relaxed copyright regex
            m_copy = match(r"(?:©|\(c\)|copyright)\s*(\d{4})\b"i, txt)
            if m_copy !== nothing
                 text_year = m_copy.captures[1]
                 @debug "Found year '$text_year' from copyright notice in text."
            end
        end

        m_etal = match(r"\b([A-Z][A-Za-z\-']{2,})\s+(?:et\s*al\.?|and\s+others)\b"i, txt)
        if m_etal !== nothing
            etal_author_raw = m_etal.captures[1]
            @debug "Found potential 'et al.' author '$etal_author_raw' in text."
        end
    else
         @debug "Could not extract text from first page of '$pdf'."
    end

    cr_auth_raw, cr_year = "", ""
    if !isempty(doi)
        @debug "Found DOI: $doi in '$pdf', querying CrossRef..."
        cr_auth_raw, cr_year = crossref(doi)
        @debug "CrossRef returned: Author='$cr_auth_raw', Year='$cr_year' for DOI $doi"
    else
        @debug "No DOI found in first page text of '$pdf'."
    end

    # --- 2. Process and Validate Candidates ---
    # Apply surname_from (which includes ascii_clean) and junk check
    meta_surname = surname_from(meta_author_raw)
    if !isempty(meta_surname) && is_likely_junk_surname(meta_surname)
        @debug "Discarding likely junk metadata Author surname: '$meta_surname' (raw: '$meta_author_raw')"
        meta_surname = ""
    elseif !isempty(meta_surname)
         @debug "Valid metadata Author surname found: '$meta_surname'"
    end

    # Be more strict with Creator field, often software names
    creator_surname = surname_from(meta_creator_raw)
    if !isempty(creator_surname) && is_likely_junk_surname(creator_surname)
        @debug "Discarding likely junk metadata Creator surname: '$creator_surname' (raw: '$meta_creator_raw')"
        creator_surname = ""
    elseif !isempty(creator_surname)
         @debug "Valid metadata Creator surname found: '$creator_surname'"
    end

    etal_surname = surname_from(etal_author_raw) # Clean the et al. heuristic surname
    if !isempty(etal_surname) && is_likely_junk_surname(etal_surname) # Also check et al. surname
        @debug "Discarding likely junk 'et al.' surname: '$etal_surname' (raw: '$etal_author_raw')"
        etal_surname = ""
    elseif !isempty(etal_surname)
         @debug "Valid 'et al.' text surname found: '$etal_surname'"
    end


    cr_surname = surname_from(cr_auth_raw) # Clean the crossref surname
    if !isempty(cr_surname) && is_likely_junk_surname(cr_surname) # Also check CrossRef just in case
         @debug "Discarding likely junk CrossRef surname: '$cr_surname' (raw: '$cr_auth_raw')"
         cr_surname = ""
    elseif !isempty(cr_surname)
         @debug "Valid CrossRef surname found: '$cr_surname'"
     end

    # --- 3. Prioritize and Select Final Values ---
    final_surname = ""
    # Priority: CrossRef > Metadata Author > Text 'et al.' Heuristic > Metadata Creator
    if !isempty(cr_surname)
        final_surname = cr_surname
        @debug "Using CrossRef surname: '$final_surname'"
    elseif !isempty(meta_surname)
        final_surname = meta_surname
        @debug "Using metadata Author surname: '$final_surname'"
    elseif !isempty(etal_surname)
        final_surname = etal_surname
        @debug "Using 'et al.' text surname: '$final_surname'"
    elseif !isempty(creator_surname) # Use Creator only as a last resort for surname
        final_surname = creator_surname
        @debug "Using metadata Creator surname as last resort: '$final_surname'"
    else
        @debug "No valid surname found after checks for '$pdf'."
    end

    final_year = ""
    # Priority: CrossRef > Metadata (CreateDate/ModifyDate) > Text (Year Regex / Copyright) > Filename
    if !isempty(cr_year) && match(YEAR_REGEX, cr_year) !== nothing
        final_year = cr_year
        @debug "Using CrossRef year: '$final_year'"
    elseif !isempty(meta_year) && match(YEAR_REGEX, meta_year) !== nothing
        final_year = meta_year
        @debug "Using metadata year: '$final_year'"
    elseif !isempty(text_year) && match(YEAR_REGEX, text_year) !== nothing
        final_year = text_year
        @debug "Using text-extracted year: '$final_year'"
    else
         # Last resort: try year from filename (basename to avoid path issues)
         fn_year = extract_year(basename(pdf))
         if !isempty(fn_year)
             final_year = fn_year
             @debug "Using filename year as last resort: '$final_year'"
         else
            @debug "No valid year found after checks for '$pdf'."
         end
    end

    # --- 4. Final Validation and Return ---
    if isempty(final_surname) || isempty(final_year)
        @warn "Could not determine valid author/year for '$pdf'. Skipping."
        return nothing
    end

    # Final length check on surname (already checked by junk filter, but double check)
    length(final_surname) < 2 && (@warn "Final surname '$final_surname' too short for '$pdf'. Skipping."; return nothing)

    return "$(final_surname)-$(final_year).pdf"
end


# ─────────────────────── rename action ────────────────────────────────────

"""
    rename!(pdf; dry=false, confirm=true, logfh=nothing)
Propose and (optionally) rename `pdf`.
Returns: :done | :skip | :dry | :exists
"""
function rename!(pdf::AbstractString; dry=false, confirm=true, logfh=nothing)
    orig = basename(pdf) # Use basename for logging and comparison
    prop_name = try proposed_name(pdf) catch e; @error "Error during name proposal for '$pdf': $e"; nothing end # Catch errors in proposal
    prop_name === nothing && return :skip # proposed_name returns nothing if data is insufficient/invalid or error occurred

    # Check if the proposed name is the same as the current name
    prop_name == orig && (@info "File '$orig' already named correctly. Skipping."; return :skip)

    tgt_dir = dirname(pdf)
    tgt_path = joinpath(tgt_dir, prop_name)

    # Handle potential filename collision robustly
    # Check if a file/dir exists at the target path AND it's not the *exact same file* we are renaming
    # realpath resolves symlinks etc. for a more reliable comparison
    if ispath(tgt_path)
        try
            if realpath(pdf) != realpath(tgt_path)
                 # Collision with a DIFFERENT file/directory
                 base, ext = splitext(prop_name)
                 found_alt = false
                 original_proposal = prop_name # Keep track of the first proposal for logging
                 for c in 'a':'z'
                     alt_name = "$(base)$(c)$(ext)"
                     alt_path = joinpath(tgt_dir, alt_name)
                     if !ispath(alt_path) # Found an unused alternative name
                         tgt_path = alt_path
                         prop_name = alt_name # Update the proposed name to the non-colliding one
                         found_alt = true
                         @info "Collision detected for '$orig' -> '$original_proposal'. Using alternative name: '$prop_name'"
                         break
                     end
                 end
                 # If no alternative 'a'-'z' worked, report collision and skip
                 if !found_alt
                      @warn "Collision: Target '$original_proposal' and alternatives a-z already exist for '$orig'. Skipping."
                      return :exists # Indicate collision prevented action
                 end
            else
                 # The target path exists but IS the original file (e.g. case change on case-insensitive FS)
                 # We can proceed with the rename, `mv` should handle this.
                 @debug "Target path '$tgt_path' is the same file as '$pdf'. Rename will proceed."
            end
        catch e
             # Error during realpath (e.g. permission denied)
             @error "Error checking path existence or realpath for '$pdf' or '$tgt_path': $e. Skipping."
             return :skip
        end
    end


    @printf "%s → %s\n" orig prop_name
    if dry
         return :dry
    end

    if confirm
        print("Apply rename? [y/N]: "); flush(stdout)
        resp = lowercase(strip(readline()))
        if resp != "y" && resp != "yes"
             println("Skipped by user.")
             return :skip
        end
    end

    try
        # Use force=true to handle the case where target is the same file (e.g. case change)
        mv(pdf, tgt_path; force=true)
        logfh !== nothing && println(logfh, "$orig ⟶ $prop_name") # Log original basename -> new basename
        println("Renamed.")
        return :done
    catch e
        @error "Failed to rename '$orig' to '$prop_name': $e"
        # Attempt to provide more specific feedback if possible
        if e isa SystemError && contains(string(e), "already exists")
             @error "Rename failed likely due to race condition or case-insensitivity issue. Target '$prop_name' may now exist."
             return :exists # Treat as collision if mv fails with "already exists"
        end
        return :skip # Treat other rename errors as skip
    end
end

# ─────────────────────────── main() ───────────────────────────────────────

# Setup logging based on verbosity flag
function configure_logging(verbose::Bool)
    level = verbose ? Logging.Debug : Logging.Info
    # Simply replace the global logger with a new one configured as desired.
    global_logger(ConsoleLogger(stderr, level))
    @debug "Verbose logging enabled." # This will only print if level is Debug
end

function main(args)
    dry_run  = false
    confirm  = true          # ask by default
    verbose = false
    files    = String[]
    log_file = nothing # Option to log renames

    i = 1
    while i ≤ length(args)
        arg = args[i]
        if arg in ("-n", "--dry-run");        dry_run = true
        elseif arg in ("-y", "--yes");        confirm = false       # no prompt
        elseif arg in ("-v", "--verbose");    verbose = true
        # Add help option
        elseif arg in ("-h", "--help");       println(stderr, """
            Usage:  julia Auctor.jl [options] <pdf | dir> ...

            Rename PDFs to "surname-year.pdf". Extracts info from metadata,
            first page text, and CrossRef (via DOI if found), prioritizing
            higher quality sources (CrossRef > Author Meta > Text Heuristic > Creator Meta).
            Handles filename collisions by appending 'a', 'b', etc.

            Requires external tools: exiftool, pdftotext, curl
            Requires Julia package: JSON (standard library in Julia >= 1.0)

            Options:
              -n, --dry-run   Preview rename operations only.
              -y, --yes       Do not ask for confirmation, rename directly.
              -v, --verbose   Show debug information for extraction steps.
              -h, --help      Show this help message and exit.
              --log <file>    Log successful renames (original -> new) to <file>.
            """); return 0 # Exit cleanly after help
        # Add log option
        elseif arg == "--log"
             i += 1
             if i > length(args)
                 println(stderr, "Error: --log option requires a filename argument.")
                 return 1
             end
             log_file = args[i]
        elseif first(arg) == '-';            println(stderr, "Unknown option: $arg. Use -h or --help for usage."); return 1
        else push!(files, arg)
        end
        i += 1
    end

    configure_logging(verbose) # Configure logging level based on flag

    if isempty(files)
        println(stderr, "Usage: julia Auctor.jl [options] <pdf | dir> ...")
        println(stderr, "Use -h or --help for more information.")
        return 1
    end

    # Check dependencies early
     missing_tools = []
     for tool in ["exiftool", "pdftotext", "curl"]
         if Sys.which(tool) === nothing
             push!(missing_tools, tool)
         end
     end
     if !isempty(missing_tools)
         @error "Required external tool(s) not found in PATH: $(join(missing_tools, ", "))"
         @error "Please install them and ensure they are accessible."
         return 2 # Specific exit code for missing deps
     end

    # gather PDFs
    todo = String[]
    @info "Scanning for PDF files..."
    for path_arg in files
        try
            # Expand user path if needed (e.g., ~/Documents)
            path = abspath(expanduser(path_arg))
            if !ispath(path)
                @warn "Input path not found: $path (original: $path_arg). Skipping."
                continue
            end
            if isdir(path)
                @debug "Scanning directory: $path"
                # Use walkdir with error handling
                for (root, dirs, files_in_dir) in walkdir(path; onerror=e->@warn("Error accessing directory during scan: $e. Skipping subtree."))
                    for f in files_in_dir
                        if endswith(lowercase(f), ".pdf")
                             fp = joinpath(root, f)
                             # Basic check if it's a real file and readable
                             if isfile(fp) && try read(fp, 1); true catch; false end
                                 @debug "Found PDF: $fp"
                                 push!(todo, fp)
                             else
                                 @warn "Skipping likely invalid or unreadable file: $fp"
                             end
                        end
                    end
                end
            elseif isfile(path) && endswith(lowercase(path), ".pdf")
                if try read(path, 1); true catch; false end
                    @debug "Adding specified PDF: $path"
                    push!(todo, path)
                else
                    @warn "Skipping likely invalid or unreadable file: $path"
                end
            else
                @warn "Skipping non-PDF file or non-directory: $path"
            end
        catch e
             @error "Error processing input path '$path_arg': $e"
             # Optionally show backtrace if verbose
             verbose && Base.show_backtrace(stderr, catch_backtrace())
        end
    end

    if isempty(todo)
        @error "No valid PDF files found in the specified paths."
        return 1
    end

    logfh = nothing
    logfilename = ""
    if log_file !== nothing
        logfilename = abspath(expanduser(log_file))
        try
            logfh = open(logfilename, "a") # Open in append mode
             println(logfh, "# Auctor.jl Log - Started: $(now())")
             println(logfh, "# Options: dry=$dry_run, confirm=$confirm, verbose=$verbose")
             @info "Logging renames to: $logfilename"
        catch e
            @error "Could not open log file '$logfilename' for writing: $e. Logging disabled."
            logfh = nothing # Ensure logfh is nothing if open failed
        end
    end

    renamed_count, skipped_count, exists_count, dry_proposals_count = 0, 0, 0, 0
    total_files = length(todo)
    println("\nProcessing $total_files PDF file(s)...")

    for (k, f) in enumerate(todo)
        println("\n---")
        @printf "[%d/%d] Processing: %s\n" k total_files f
        try
            # Pass the potentially opened log file handle
            status = rename!(f; dry=dry_run, confirm=confirm, logfh=logfh)

            if status == :done
                renamed_count += 1
            elseif status == :skip
                 skipped_count += 1
            elseif status == :exists
                 exists_count += 1
            elseif status == :dry
                 dry_proposals_count += 1
            end
        catch e
            @error "Unexpected error processing file '$f': $e"
            # Show backtrace in verbose mode for unexpected errors in the loop
            verbose && Base.show_backtrace(stderr, catch_backtrace())
            skipped_count += 1 # Count unexpected errors as skipped
        end
    end

    # Close log file if it was opened
    if logfh !== nothing
         println(logfh, "# Finished: $(now())")
         println(logfh, "# Renamed: $renamed_count, Skipped: $skipped_count, Collisions: $exists_count")
         try close(logfh) catch e; @warn "Error closing log file '$logfilename': $e" end
    end

    println("\n--- Summary ---")
    if dry_run
        println("Dry run complete.")
        println("Proposed renames for $dry_proposals_count files.")
        total_skipped_or_exists = skipped_count + exists_count
        println("Skipped $total_skipped_or_exists files (no change needed, missing info, potential collision, or error).")
        exists_count > 0 && println("$exists_count potential collisions detected.")
    else
        println("Renamed $renamed_count files.")
        total_skipped_or_exists = skipped_count + exists_count
        println("Skipped $total_skipped_or_exists files (no change, missing info, user skip, collision, or error).")
        exists_count > 0 && println("$exists_count collisions prevented renaming.")
        !isempty(logfilename) && logfh !== nothing && println("Log file: $logfilename")
    end

    # Exit code: 0 if any files were renamed or proposed successfully, 1 otherwise.
    # Exit 1 indicates nothing was done or only errors/skips occurred.
    return (renamed_count > 0 || dry_proposals_count > 0) ? 0 : 1
end


# --- Entry Point ---
if abspath(PROGRAM_FILE) == @__FILE__
    # Call main function and exit with its status code
    # Dependency checks are now inside main() to allow -h/--help without them.
    exit_code = main(ARGS)
    exit(exit_code)
end
