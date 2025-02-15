#!/usr/bin/env bats

setup() {
  # Create a temporary directory for test files.
  TMP_DIR=$(mktemp -d)

  # Override pbcopy so that it does nothing.
  pbcopy() { :; }
}

teardown() {
  rm -rf "$TMP_DIR"
}

# Load the assemble-prompt component. Adjust the path if needed.
load "${BATS_TEST_DIRNAME}/assemble-prompt.sh"

@test "assemble-prompt formats output correctly with fixed instruction" {
  # Create two temporary Swift files.
  file1="$TMP_DIR/File1.swift"
  file2="$TMP_DIR/File2.swift"

  # File1 contains a TODO marker in the old format.
  cat <<'EOF' > "$file1"
class MyClass {
    // TODO: - Do something important
}
EOF

  # File2 contains a simple struct definition.
  cat <<'EOF' > "$file2"
struct MyStruct {}
EOF

  # Create a temporary file listing found file paths (including a duplicate).
  found_files_file="$TMP_DIR/found_files.txt"
  echo "$file1" > "$found_files_file"
  echo "$file2" >> "$found_files_file"
  echo "$file1" >> "$found_files_file"  # duplicate entry to test deduplication.

  # Define a sample instruction content that should be ignored.
  instruction_content="This is the instruction content that will be ignored."

  # Run the assemble-prompt function.
  run assemble-prompt "$found_files_file" "$instruction_content"
  [ "$status" -eq 0 ]

  # Check that the output includes the headers for both files.
  [[ "$output" == *"The contents of File1.swift is as follows:"* ]]
  [[ "$output" == *"The contents of File2.swift is as follows:"* ]]
  
  # Verify that the TODO marker is replaced.
  [[ "$output" == *"// TODO: ChatGPT: Do something important"* ]]

  # Check that the content from each file is present.
  [[ "$output" == *"class MyClass {"* ]]
  [[ "$output" == *"struct MyStruct {}"* ]]
  
  # Confirm that the fixed instruction content is appended at the end.
  fixed_instruction="Can you do the TODO:- in the above code? But ignoring all FIXMEs and other TODOs...i.e. only do the one and only one TODO that is marked by \"// TODO: - \", i.e. ignore things like \"// TODO: example\" because it doesn't have the hyphen"
  [[ "$output" == *"$fixed_instruction"* ]]
}

@test "assemble-prompt processes files with substring markers correctly" {
  # Create a temporary Swift file that includes substring markers.
  file_with_markers="$TMP_DIR/MarkedFile.swift"
  cat <<'EOF' > "$file_with_markers"
import Foundation
// v
func secretFunction() {
    print("This is inside the markers.")
}
// ^
func publicFunction() {
    print("This is outside the markers.")
}
EOF

  # Create a temporary file listing the file path.
  found_files_file="$TMP_DIR/found_files_markers.txt"
  echo "$file_with_markers" > "$found_files_file"

  # Run the assemble-prompt function.
  run assemble-prompt "$found_files_file" "ignored instruction"
  [ "$status" -eq 0 ]

  # Check that the output includes a header for MarkedFile.swift.
  [[ "$output" == *"The contents of MarkedFile.swift is as follows:"* ]]

  # Based on our filter-substring-markers.sh behavior, the expected
  # filtered output should include only the content between the markers (with placeholder blocks).
  # For example, if filter_substring_markers outputs:
  #
  #   (blank line)
  #   // ...
  #   (blank line)
  #   func secretFunction() {
  #       print("This is inside the markers.")
  #   }
  #   (blank line)
  #   // ...
  #   (blank line)
  #
  # then we can check that:
  [[ "$output" == *"func secretFunction() {"* ]]
  [[ "$output" == *"print(\"This is inside the markers.\")"* ]]
  # And importantly, it should NOT include the content outside the markers:
  [[ "$output" != *"func publicFunction() {"* ]]
}

@test "assemble-prompt includes diff output when DIFF_WITH_BRANCH is set" {
  # Create a temporary Swift file.
  file1="$TMP_DIR/FileDiff.swift"
  echo "class Dummy {}" > "$file1"

  # Create a temporary file listing the file path.
  found_files_file="$TMP_DIR/found_files_diff.txt"
  echo "$file1" > "$found_files_file"

  # Set DIFF_WITH_BRANCH so that diff logic is activated.
  export DIFF_WITH_BRANCH="dummy-branch"

  # Override get_diff_with_branch to simulate a diff.
  get_diff_with_branch() {
    echo "Dummy diff output for $(basename "$1")"
  }

  # Run assemble-prompt.
  run assemble-prompt "$found_files_file" "ignored"
  [ "$status" -eq 0 ]
  # Check that the output contains the simulated diff output.
  [[ "$output" == *"Dummy diff output for FileDiff.swift"* ]]
  [[ "$output" == *"against branch dummy-branch"* ]]

  unset DIFF_WITH_BRANCH
}

@test "assemble-prompt prints warning when prompt exceeds threshold" {
  # Create a huge temporary Swift file.
  file_huge="$TMP_DIR/Huge.swift"
  # Write 100,500 characters into the file (for example, by repeating a pattern).
  head -c 100500 /dev/zero | tr '\0' 'a' > "$file_huge"
  # Prepend a valid TODO instruction so that the file is selected.
  sed -i '' '1s/^/\/\/ TODO: - Huge instruction\n/' "$file_huge"
  
  # Create a temporary file listing the huge file.
  found_files_file="$TMP_DIR/found_files_huge.txt"
  echo "$file_huge" > "$found_files_file"
  
  # Run the assemble-prompt function.
  run assemble-prompt "$found_files_file" "ignored"
  [ "$status" -eq 0 ]
  # Check that the output contains the warning message from check_prompt_size.
  [[ "$output" == *"Warning: The prompt is"* ]]
}
