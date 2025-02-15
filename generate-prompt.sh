#!/bin/bash
set -euo pipefail

##########################################
# generate-prompt.sh
#
# This script finds the unique Swift file that contains a
# TODO instruction (specifically “// TODO: - ”),
# processes it along with related type definitions in the repository,
# and then assembles a ChatGPT prompt that is copied to the clipboard.
#
# Usage:
#   generate-prompt.sh [--slim] [--singular] [--force-global] [--include-references] [--diff-with <branch>] [--exclude <filename>] [--verbose] [--exclude <another_filename>] ...
#
# Options:
#   --slim         Only include the file that contains the TODO instruction
#                  and “model” files. In slim mode, files whose names contain
#                  keywords such as “ViewController”, “Manager”, “Presenter”,
#                  “Configurator”, “Router”, “DataSource”, “Delegate”, or “View”
#                  are excluded.
#   --singular     Only include the Swift file that contains the TODO instruction.
#   --force-global Use the entire Git repository for context inclusion, even if the TODO file is in a package.
#   --include-references
#                  Additionally include files that reference the enclosing type.
#   --diff-with <branch>
#                  For each included file that differs from the specified branch,
#                  include a diff report. (e.g. --diff-with main or --diff-with develop)
#   --exclude      Exclude any file whose basename matches the provided filename.
#   --verbose      Enable verbose console logging for debugging purposes.
#
# Note:
#   You must write your question in the form // TODO: - (including the hyphen).
#
# It sources the following components:
#   - assemble-prompt.sh            : Assembles the final prompt and copies it to the clipboard.
#   - find-definition-files.sh         : Finds Swift files containing definitions for the types.
#
# New for reference inclusion:
#   --include-references
#                  Additionally include files that reference the enclosing type.
#
# New for diff inclusion:
#   --diff-with <branch>              For each included file that differs from the
#                                     specified branch, include a diff report.
##########################################

# Process optional parameters.
SLIM=false
SINGULAR=false
VERBOSE=false
FORCE_GLOBAL=false
INCLUDE_REFERENCES=false
# DIFF_WITH_BRANCH will be set by the --diff-with option.
EXCLUDES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --slim)
            SLIM=true
            shift
            ;;
        --singular)
            SINGULAR=true
            shift
            ;;
        --force-global)
            FORCE_GLOBAL=true
            shift
            ;;
        --include-references)
            INCLUDE_REFERENCES=true
            shift
            ;;
        --diff-with)
            if [ -n "${2:-}" ]; then
                export DIFF_WITH_BRANCH="$2"
                shift 2
            else
                echo "Usage: $0 [--diff-with <branch>]" >&2
                exit 1
            fi
            ;;
        --exclude)
            if [ -n "${2:-}" ]; then
                EXCLUDES+=("$2")
                shift 2
            else
                echo "Usage: $0 [--exclude <filename>]" >&2
                exit 1
            fi
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Usage: $0 [--slim] [--singular] [--force-global] [--include-references] [--diff-with <branch>] [--exclude <filename>] [--verbose]" >&2
            exit 1
            ;;
    esac
done

# Export VERBOSE so that helper scripts can use it.
export VERBOSE

# Save the directory where you invoked the script.
CURRENT_DIR="$(pwd)"

# Determine the directory where this script resides.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source external components from SCRIPT_DIR.
source "$SCRIPT_DIR/assemble-prompt.sh"

# Source additional helpers (if needed).
if [ "$SINGULAR" = false ]; then
    source "$SCRIPT_DIR/find-definition-files.sh"
    # Note: The old filter-files.sh is no longer sourced, as its logic is now provided by the Rust binary.
fi

echo "--------------------------------------------------"

# Change back to the directory where the command was invoked.
cd "$CURRENT_DIR"

# Determine the Git repository root using the new Rust binary.
GIT_ROOT=$("$SCRIPT_DIR/rust/target/release/get_git_root") || exit 1
echo "Git root: $GIT_ROOT"

# Move to the repository root.
cd "$GIT_ROOT"

# Use the Rust binary to locate the file with the TODO instruction.
FILE_PATH=$("$SCRIPT_DIR/rust/target/release/find_prompt_instruction" "$GIT_ROOT") || exit 1
echo "Found exactly one instruction in $FILE_PATH"

export TODO_FILE_BASENAME=$(basename "$FILE_PATH")

# --- Enforce singular mode for JavaScript files (beta support) ---
if [[ "$FILE_PATH" == *.js ]]; then
    if [ "$SINGULAR" = false ]; then
        echo "WARNING: JavaScript support is currently in beta. Singular mode will be enforced, so only the file containing the TODO instruction will be used for context." >&2
        SINGULAR=true
    fi
fi

# --- Check for --include-references ---
if [ "$INCLUDE_REFERENCES" = true ]; then
    if [[ "$FILE_PATH" != *.swift ]]; then
        echo "Error: The --include-references option is currently only supported for Swift files. The TODO instruction was found in a non-Swift file: $(basename "$FILE_PATH")" >&2
        exit 1
    fi
fi

# --- Determine Package Scope ---
PACKAGE_ROOT=$("$SCRIPT_DIR/rust/target/release/get-package-root" "$FILE_PATH" 2>/dev/null || echo "")
if [ "${FORCE_GLOBAL}" = true ]; then
    echo "Force global enabled: ignoring package boundaries and using Git root for context."
    SEARCH_ROOT="$GIT_ROOT"
elif [ -n "$PACKAGE_ROOT" ]; then
    echo "Found package root: $PACKAGE_ROOT"
    SEARCH_ROOT="$PACKAGE_ROOT"
else
    SEARCH_ROOT="$GIT_ROOT"
fi
# --- End Package Scope ---

# Extract the instruction content from the file using the Rust binary.
INSTRUCTION_CONTENT=$("$SCRIPT_DIR/rust/target/release/extract_instruction_content" "$FILE_PATH")

if [ "$SINGULAR" = true ]; then
    echo "Singular mode enabled: only including the TODO file"
    FOUND_FILES=$("$SCRIPT_DIR/rust/target/release/filter_files_singular" "$FILE_PATH")
else
    # Extract potential type names from the Swift file.
    TYPES_FILE=$("$SCRIPT_DIR/rust/target/release/extract_types" "$FILE_PATH")
    
    # Find Swift files containing definitions for the types.
    FOUND_FILES=$(find-definition-files "$TYPES_FILE" "$SEARCH_ROOT")
    
    # Ensure the chosen TODO file is included in the found files.
    echo "$FILE_PATH" >> "$FOUND_FILES"
    
    # If slim mode is enabled, filter the FOUND_FILES list using the new Rust binary.
    if [ "$SLIM" = true ]; then
         echo "Slim mode enabled: filtering files to include only the TODO file and model files..."
         FOUND_FILES=$("$SCRIPT_DIR/rust/target/release/filter_files" "$FILE_PATH" "$FOUND_FILES")
    fi
    
    # If any exclusions were specified, filter them out using the new Rust binary.
    if [ "${#EXCLUDES[@]}" -gt 0 ]; then
         echo "Excluding files matching: ${EXCLUDES[*]}"
         FOUND_FILES=$("$SCRIPT_DIR/rust/target/release/filter_excluded_files" "$FOUND_FILES" "${EXCLUDES[@]}")
    fi
fi

# --- Include referencing files if requested ---
if [ "${INCLUDE_REFERENCES:-false}" = true ]; then
    echo "Including files that reference the enclosing type..."
    # Use the new Rust binary to extract the enclosing type.
    enclosing_type=$("$SCRIPT_DIR/rust/target/release/extract_enclosing_type" "$FILE_PATH")
    if [ -n "$enclosing_type" ]; then
        echo "Found enclosing type '$enclosing_type'. Searching for files that reference '$enclosing_type' in: $SEARCH_ROOT"
        referencing_files=$("$SCRIPT_DIR/rust/target/release/find_referencing_files" "$enclosing_type" "$SEARCH_ROOT")
        # Append the referencing files to the FOUND_FILES list.
        cat "$referencing_files" >> "$FOUND_FILES"
        rm -f "$referencing_files"
    else
        echo "No enclosing type found in $FILE_PATH, skipping reference search."
    fi
fi
# --- End reference inclusion ---

# Register a trap to clean up temporary files.
cleanup_temp_files() {
    [[ -n "${TYPES_FILE:-}" ]] && rm -f "$TYPES_FILE"
    [[ -n "${FOUND_FILES:-}" ]] && rm -f "$FOUND_FILES"
}
trap cleanup_temp_files EXIT

echo "--------------------------------------------------"
if [ "$SINGULAR" = false ]; then
    echo "Types found:"
    cat "$TYPES_FILE"
    echo "--------------------------------------------------"
fi

echo "Files (final list):"
sort "$FOUND_FILES" | uniq | while read -r file_path; do
    basename "$file_path"
done

# Assemble the final clipboard content and copy it to the clipboard.
FINAL_CLIPBOARD_CONTENT=$(assemble-prompt "$FOUND_FILES" "$INSTRUCTION_CONTENT")

echo "--------------------------------------------------"
echo
echo "Success:"
echo
echo "$INSTRUCTION_CONTENT"
if [ "$INCLUDE_REFERENCES" = true ]; then
    echo
    echo "Warning: The --include-references option is experimental and may produce unexpected results."
fi
echo
echo "--------------------------------------------------"
