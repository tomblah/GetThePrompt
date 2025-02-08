#!/bin/bash
set -euo pipefail

##########################################
# get-the-prompt.sh
#
# This script finds the unique Swift file that contains a
# TODO instruction (either “// TODO: - ” or “// TODO: ChatGPT: ”),
# processes it along with related type definitions in the repository,
# and then assembles a ChatGPT prompt that is copied to the clipboard.
#
# It sources the following components:
#   - find_prompt_instruction.sh : Locates the unique Swift file with the TODO.
#   - extract_types.sh           : Extracts potential type names from a Swift file.
#   - find_definition_files.sh   : Finds Swift files containing definitions for the types.
##########################################

# Determine the directory where this script resides.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source external components.
source "$SCRIPT_DIR/find_prompt_instruction.sh"
source "$SCRIPT_DIR/extract_types.sh"
source "$SCRIPT_DIR/find_definition_files.sh"

echo "--------------------------------------------------"

# Change to the directory of the script.
cd "$SCRIPT_DIR"

# Determine the root directory of the Git repository.
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$GIT_ROOT" ]; then
    echo "Error: Not a git repository." >&2
    exit 1
fi
echo "Git root: $GIT_ROOT"

# Move to the repository root.
cd "$GIT_ROOT"

# Use the external component to locate the file with the TODO instruction.
FILE_PATH=$(find_prompt_instruction "$GIT_ROOT") || exit 1
echo "Found exactly one instruction in $FILE_PATH"

# Extract the instruction content from the file.
# (This extracts the first matching line from the file.)
INSTRUCTION_CONTENT=$(grep -E '// TODO: (ChatGPT: |- )' "$FILE_PATH" | head -n 1 | sed 's/^[[:space:]]*//')

# Use the extract_types component to get potential type names from the Swift file.
TYPES_FILE=$(extract_types "$FILE_PATH")

echo "--------------------------------------------------"
echo "Types found:"
cat "$TYPES_FILE"
echo "--------------------------------------------------"

# Use find_definition_files to search for Swift files containing definitions.
FOUND_FILES=$(find_definition_files "$TYPES_FILE" "$GIT_ROOT")

echo "Files:"
sort "$FOUND_FILES" | uniq | while read -r file_path; do
    basename "$file_path"
done

# Assemble the final clipboard content.
UNIQUE_FOUND_FILES=$(sort "$FOUND_FILES" | uniq)
CLIPBOARD_CONTENT=""

while read -r file_path; do
    FILE_BASENAME=$(basename "$file_path")
    FILE_CONTENT=$(cat "$file_path")
    CLIPBOARD_CONTENT+="The contents of $FILE_BASENAME is as follows:\n\n$FILE_CONTENT\n\n--------------------------------------------------\n"
done <<< "$UNIQUE_FOUND_FILES"

# Replace occurrences of "// TODO: - " with "// TODO: ChatGPT: "
MODIFIED_CLIPBOARD_CONTENT=$(echo -e "$CLIPBOARD_CONTENT" | sed 's/\/\/ TODO: - /\/\/ TODO: ChatGPT: /g')

# Append the instruction content to the final clipboard content.
FINAL_CLIPBOARD_CONTENT="$MODIFIED_CLIPBOARD_CONTENT\n\n$INSTRUCTION_CONTENT"

# Copy the final content to the clipboard using pbcopy.
echo -e "$FINAL_CLIPBOARD_CONTENT" | pbcopy

echo "--------------------------------------------------"
echo
echo "Success:"
echo
echo "$INSTRUCTION_CONTENT"
echo
echo "--------------------------------------------------"
