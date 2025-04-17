#!/usr/bin/env julia
# Auctor.jl  –  rename PDF → surname‑year.pdf
#
# Requires external tools: exiftool, pdftotext, curl
# Julia deps: JSON (std‑lib: Unicode, Dates, Printf).
# If needed:  using Pkg; Pkg.add("JSON")

using JSON, Unicode, Dates, Printf

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
        return p.exitcode == 0 ? fetch(s_out) : ""
    catch
        try close(out; allowerror=true) catch; end # Ensure pipe is closed on error
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
    buf = IOBuffer()
    for c in Unicode.normalize(s, :NFD)
        if isascii(c)
            if isletter(c) || isdigit(c) || c == '_' || c == '-'
                write(buf, c)
            end
        # Allow non-ASCII letters after normalization if needed by changing the condition
        # elseif isletter(c)
        #    write(buf, c)
        end
    end
    # Drop leading/trailing hyphens/underscores and replace multiple with single
    cleaned = lowercase(String(take!(buf)))
    cleaned = replace(cleaned, r"[-_]{2,}" => "-")
    cleaned = replace(cleaned, r"^[_-]+|[_-]+$" => "")
    return cleaned
end

# More specific year regex
const YEAR_REGEX = r"\b(19[89]\d|20\d{2})\b"
extract_year(s::AbstractString)::String = (m = match(YEAR_REGEX, s)) === nothing ? "" : m.captures[1]

"""
    surname_from(author_string)
Take potential author string, find first author block, return cleaned surname.
"""
function surname_from(author_string::AbstractString)::String
    isempty(author_string) && return ""
    # Handle common separators including 'and' and '&'
    first_author_block = split(author_string, r"(\s*,\s*|\s*;\s*|\s+and\s+|\s*&\s*)", limit=2)[1]
    tokens = split(strip(first_author_block))
    isempty(tokens) ? "" : ascii_clean(last(tokens))
end

"""
    is_likely_junk_surname(s) :: Bool
Heuristic check if a string is unlikely to be a real surname (e.g., software name, number).
"""
function is_likely_junk_surname(s::AbstractString)::Bool
    isempty(s) && return true
    length(s) < 2 && return true # Too short is suspicious
    # Mostly digits indicates version numbers etc.
    (count(isdigit, s) / length(s)) > 0.6 && return true
    # Contains common software/publisher terms (case-insensitive)
    occursin(r"(publisher|publishing|arbortext|adobe|acrobat|microsoft|word|writer|creator|incopy|tex|latex|elsevier|springer|wiley|taylor|francis|\d+\.\d+|service|Ltd|Inc|GmbH)"i, s) && return true
    # Starts with non-letter
    !isletter(first(s)) && return true
    return false
end


firstpage_text(pdf::AbstractString)::String = capture(`pdftotext -f 1 -l 1 "$pdf" -`) # Added quotes for safety

doi_in(txt::AbstractString)::String = (m = match(r"\b10\.\d{4,9}/[-._;()/:A-Z0-9]+\b"i, txt)) === nothing ? "" : m.match # case-insensitive

"""
    crossref(doi) :: (surname, year)
Minimal CrossRef query, return first author surname and year if found.
"""
function crossref(doi::AbstractString)
    (isempty(doi) || !startswith(doi, "10.")) && return "", ""
    # Use "-H 'Accept: application/json'" for robustness
    raw = capture(`curl -sS --connect-timeout 5 --max-time 10 -L -H 'Accept: application/json' "https://api.crossref.org/works/$(doi)"`)
    raw == "" && return "", ""
    data = try JSON.parse(raw) catch e; @debug "JSON parse error for DOI $doi: $e"; return "", "" end

    msg = get(data, "message", nothing)
    msg === nothing && return "", ""

    # Extract author surname
    auth_raw = ""
    authors = get(msg, "author", nothing)
    if authors isa Vector && !isempty(authors) && authors[1] isa Dict
        # Prefer 'family' name, fallback to 'name' if 'family' not present
        surname = get(authors[1], "family", get(authors[1], "name", nothing))
        if surname isa AbstractString && !isempty(surname)
            # If 'name' field was used, it might contain full name, try to get last word
             if !haskey(authors[1], "family") && occursin(r"\s", surname) # Check for space
                 auth_raw = split(surname)[end]
             else
                 auth_raw = surname
             end
        end
    end

    # Extract year using chained gets - prioritize print date, then issued, then created
    year_val = nothing
    date_sources = ["published-print", "published-online", "issued", "created"] # Added published-online
    for source_key in date_sources
        source = get(msg, source_key, nothing)
        if source isa Dict
            dp = get(source, "date-parts", nothing)
            if dp isa Vector && !isempty(dp) && dp[1] isa Vector && !isempty(dp[1]) && dp[1][1] isa Integer
                year_val = dp[1][1]
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
    meta = capture(`exiftool -j -Author -Creator -CreateDate -ModifyDate "$pdf"`) # Added quotes
    if !isempty(meta)
        json_data = try JSON.parse(meta) catch; [] end
        if !isempty(json_data) && json_data[1] isa Dict
            m = json_data[1]
            meta_author_raw = get(m, "Author", "")
            meta_creator_raw = get(m, "Creator", "") # Get Creator separately
            meta_year   = extract_year(get(m, "CreateDate", get(m, "ModifyDate", "")))
        end
    end

    txt = firstpage_text(pdf)
    doi = ""
    text_year = ""
    etal_author_raw = ""
    if !isempty(txt)
        doi = doi_in(txt)
        text_year = extract_year(txt)
        # Fallback: Check near copyright symbol if year still missing
        if isempty(text_year)
            m_copy = match(r"(?:©|\(c\)|copyright)\s*(\d{4})\b"i, txt)
            text_year = m_copy === nothing ? "" : m_copy.captures[1]
        end
        # Heuristic for author from text (e.g., "Hassell et al.")
        m_etal = match(r"\b([A-Z][A-Za-z\-']{2,})\s+(?:et al\.?|and others)\b"i, txt)
        etal_author_raw = m_etal === nothing ? "" : m_etal.captures[1]
    end

    cr_auth_raw, cr_year = "", ""
    if !isempty(doi)
        @debug "Found DOI: $doi, querying CrossRef..."
        cr_auth_raw, cr_year = crossref(doi)
        @debug "CrossRef returned: Author='$cr_auth_raw', Year='$cr_year'"
    end

    # --- 2. Process and Validate Candidates ---
    meta_surname = surname_from(meta_author_raw)
    if !isempty(meta_surname) && is_likely_junk_surname(meta_surname)
        @debug "Discarding likely junk metadata Author surname: '$meta_surname'"
        meta_surname = ""
    end

    # Be more strict with Creator field
    creator_surname = surname_from(meta_creator_raw)
    if !isempty(creator_surname) && is_likely_junk_surname(creator_surname)
        @debug "Discarding likely junk metadata Creator surname: '$creator_surname'"
        creator_surname = ""
    end

    etal_surname = surname_from(etal_author_raw) # Assume 'et al.' heuristic is less likely junk

    cr_surname = surname_from(cr_auth_raw)
     if !isempty(cr_surname) && is_likely_junk_surname(cr_surname) # Also check CrossRef just in case
         @debug "Discarding likely junk CrossRef surname: '$cr_surname'"
         cr_surname = ""
     end

    # --- 3. Prioritize and Select Final Values ---
    final_surname = ""
    if !isempty(cr_surname)
        final_surname = cr_surname
        @debug "Using CrossRef surname: '$final_surname'"
    elseif !isempty(meta_surname)
        final_surname = meta_surname
        @debug "Using metadata Author surname: '$final_surname'"
    elseif !isempty(etal_surname)
        final_surname = etal_surname
        @debug "Using 'et al.' text surname: '$final_surname'"
    elseif !isempty(creator_surname) # Use Creator only as a last resort
        final_surname = creator_surname
        @debug "Using metadata Creator surname as last resort: '$final_surname'"
    else
        @debug "No valid surname found."
    end

    final_year = ""
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
         # Last resort: try year from filename
         fn_year = extract_year(basename(pdf))
         if !isempty(fn_year)
             final_year = fn_year
             @debug "Using filename year as last resort: '$final_year'"
         else
            @debug "No valid year found."
         end
    end

    # --- 4. Final Validation and Return ---
    if isempty(final_surname) || isempty(final_year)
        @warn "Could not determine valid author/year for '$pdf'. Skipping."
        return nothing
    end

    # Final length check on surname
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
    orig = basename(pdf)
    prop_name = proposed_name(pdf) # This now contains the prioritization logic
    prop_name === nothing && return :skip # proposed_name returns nothing if data is insufficient/invalid
    prop_name == orig && (@info "File '$orig' already named correctly. Skipping."; return :skip) # Already named correctly

    tgt_dir = dirname(pdf)
    tgt_path = joinpath(tgt_dir, prop_name)

    # Handle potential filename collision
    if ispath(tgt_path) && realpath(pdf) != realpath(tgt_path) # Check if it exists and is not the same file
        base, ext = splitext(prop_name)
        found_alt = false
        for c in 'a':'z'
            alt_name = "$(base)$(c)$(ext)"
            alt_path = joinpath(tgt_dir, alt_name)
            if !ispath(alt_path)
                tgt_path = alt_path
                prop_name = alt_name # Update the proposed name to the non-colliding one
                found_alt = true
                @info "Collision detected for '$orig'. Using alternative name: '$prop_name'"
                break
            end
        end
        # If no alternative 'a'-'z' worked, report collision and skip
        if !found_alt
             @warn "Collision: Target '$prop_name' and alternatives a-z already exist for '$orig'. Skipping."
             return :exists
        end
    end

    @printf "%s → %s\n" orig prop_name
    dry && return :dry
    if confirm
        print("Apply rename? [y/N]: "); flush(stdout)
        resp = lowercase(strip(readline()))
        if resp != "y" && resp != "yes"
             println("Skipped by user.")
             return :skip
        end
    end

    try
        mv(pdf, tgt_path; force=true) # force=true to overwrite if somehow check failed (e.g. race)
        logfh !== nothing && println(logfh, "$orig ⟶ $prop_name") # Log original basename -> new basename
        println("Renamed.")
        return :done
    catch e
        @error "Failed to rename '$orig' to '$prop_name': $e"
        return :skip # Treat rename error as skip
    end
end

# ─────────────────────────── main() ───────────────────────────────────────

# Setup logging based on verbosity flag
using Logging
function configure_logging(verbose::Bool)
    level = verbose ? Logging.Debug : Logging.Info
    global_logger(ConsoleLogger(stderr, level))
end

function main(args)
    dry_run  = false
    confirm  = true          # ask by default
    verbose = false
    files    = String[]

    i = 1
    while i ≤ length(args)
        arg = args[i]
        if arg in ("-n", "--dry-run");        dry_run = true
        elseif arg in ("-y", "--yes");        confirm = false       # no prompt
        elseif arg in ("-v", "--verbose");    verbose = true
        elseif first(arg) == '-';            println(stderr, "Unknown option: $arg"); return 1
        else push!(files, arg)
        end
        i += 1
    end

    configure_logging(verbose) # Configure logging level

    if isempty(files)
        println(stderr, """
        Usage:  julia Auctor.jl [options] <pdf | dir> ...

        Rename PDFs to "surname-year.pdf". Extracts info from metadata,
        first page text, and CrossRef (via DOI if found), prioritizing
        higher quality sources (CrossRef > Author Meta > Text Heuristic > Creator Meta).

        Requires: exiftool, pdftotext, curl

        Options:
          -n, --dry-run   Preview rename operations only.
          -y, --yes       Do not ask for confirmation, rename directly.
          -v, --verbose   Show debug information for extraction steps.
        """)
        return 1
    end

    # gather PDFs
    todo = String[]
    @info "Scanning for PDF files..."
    for path in files
        try
            # Expand user path if needed (e.g., ~/Documents)
            path = abspath(expanduser(path))
            if !ispath(path)
                @warn "No such path: $path"
                continue
            end
            if isdir(path)
                @debug "Scanning directory: $path"
                for (r, _, fs) in walkdir(path; onerror=e->@warn("Skipping dir scan error: $e"))
                    for f in fs
                        if endswith(lowercase(f), ".pdf")
                             fp = joinpath(r, f)
                             @debug "Found PDF: $fp"
                             push!(todo, fp)
                        end
                    end
                end
            elseif isfile(path) && endswith(lowercase(path), ".pdf")
                @debug "Adding specified PDF: $path"
                push!(todo, path)
            else
                @warn "Skipping non-PDF file or non-directory: $path"
            end
        catch e
             @error "Error processing path '$path': $e"
        end
    end

    if isempty(todo)
        @error "No PDF files found in the specified paths."
        return 1
    end

    logfh = nothing
    logfilename = ""
    # if !dry_run
    #     try
    #          logfilename = "/tmp/auctor_"*Dates.format(now(),"yyyymmdd_HHMMSS")*".log"
    #          logfh = open(logfilename, "w")
    #          println(logfh, "# Auctor Log: $(now())")
    #          println(logfh, "# Format: original_basename ⟶ new_basename")
    #          println(logfh, "# Processed $(length(todo)) files.")
    #          @info "Logging renames to: $logfilename"
    #     catch e
    #          @error "Could not open log file '$logfilename': $e. Logging disabled."
    #          logfh = nothing
    #     end
    # end

    ren, skip, exists_err, dry_proposals = 0, 0, 0, 0
    total = length(todo)
    println("\nProcessing $total PDF file(s)...")

    for (k, f) in enumerate(todo)
        println("\n---")
        @printf "[%d/%d] Processing: %s\n" k total f
        try
            st = rename!(f; dry=dry_run, confirm=confirm, logfh=logfh)
            if st == :done
                ren += 1
            elseif st == :skip
                 skip += 1
            elseif st == :exists
                 exists_err += 1
                 # skip += 1 # Don't double count exists as skipped here, handled below
            elseif st == :dry
                 dry_proposals += 1
            end
        catch e
            @error "Unexpected error processing file '$f': $e"
            showerror(stderr, e)
            Base.show_backtrace(stderr, catch_backtrace())
            println(stderr)
            skip += 1 # Count errors as skipped
        end
    end

    # Final count for skipped includes exists errors
    total_skipped = skip + exists_err

    if logfh !== nothing
         println(logfh, "# Finished: $(now())")
         println(logfh, "# Renamed: $ren, Skipped: $total_skipped, Collisions: $exists_err")
         try close(logfh) catch; end
    end

    println("\n--- Summary ---")
    if dry_run
        println("Dry run complete.")
        println("Proposed renames for $dry_proposals files.")
        println("Skipped $total_skipped files (no change needed, missing info, or collision).")
        exists_err > 0 && println("$exists_err potential collisions detected.")
    else
        println("Renamed $ren files.")
        println("Skipped $total_skipped files (no change, missing info, user skip, or collision).")
        exists_err > 0 && println("$exists_err collisions prevented renaming.")
        !isempty(logfilename) && println("Log file: $logfilename")
    end

    # Exit code: 0 if any files were renamed or proposed, 1 otherwise (or error)
    # Exit 1 if nothing was done or proposed
    return (ren > 0 || dry_proposals > 0) ? 0 : 1
end


# Ensure Pkg is only used if needed, avoid top-level side effects if possible
# Instead of Pkg.add, maybe just check dependencies manually or provide instructions.

if abspath(PROGRAM_FILE) == @__FILE__
    # Check for external tools before running main logic
    missing_tools = []
    for tool in ["exiftool", "pdftotext", "curl"]
        try
            # Use `Sys.which` for cross-platform check
            if Sys.which(tool) === nothing
                push!(missing_tools, tool)
            end
        catch
            push!(missing_tools, tool) # Fallback catch
        end
    end

    if !isempty(missing_tools)
        println(stderr, "Error: Required external tool(s) not found in PATH: ", join(missing_tools, ", "))
        println(stderr, "Please install them and ensure they are accessible.")
        exit(2)
    end

    # Check for JSON package (part of stdlib > 1.0, but good practice for older versions)
    try
        # Using JSON is already at the top, this just ensures no cryptic LoadError later
    catch e
        println(stderr, "Error: Julia package 'JSON' not found or loadable.")
        println(stderr, "If using Julia < 1.6, you might need to run: using Pkg; Pkg.add(\"JSON\")")
        println(stderr, "Details: $e")
        exit(3)
    end

    # Call main function and exit with its status code
    exit(main(ARGS))
end
