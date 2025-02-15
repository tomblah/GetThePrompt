use regex::Regex;
use std::collections::BTreeSet;
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;

/// Reads a Swift file, extracts potential type names using two regexes,
/// writes the sorted unique type names to a temporary file (persisted),
/// and returns the path to that file as a String.
fn extract_types_from_file<P: AsRef<Path>>(swift_file: P) -> Result<String, Box<dyn std::error::Error>> {
    // Open the Swift file.
    let file = File::open(&swift_file)?;
    let reader = BufReader::new(file);

    // Regex to match tokens that start with a capital letter.
    let re_simple = Regex::new(r"^[A-Z][A-Za-z0-9]+$")?;
    // Regex to match tokens in bracket notation (e.g. [TypeName]).
    let re_bracket = Regex::new(r"^\[([A-Z][A-Za-z0-9]+)\]$")?;

    // Use a BTreeSet to store unique type names (sorted alphabetically).
    let mut types = BTreeSet::new();

    for line in reader.lines() {
        let mut line = line?;
        // Preprocessing: replace non-alphanumeric characters with whitespace.
        line = line.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { ' ' }).collect();
        let line = line.trim();

        // Skip empty lines or lines starting with "import " or "//".
        if line.is_empty() || line.starts_with("import ") || line.starts_with("//") {
            continue;
        }

        // Split the line into tokens and check each one.
        for token in line.split_whitespace() {
            if re_simple.is_match(token) {
                types.insert(token.to_string());
            } else if let Some(caps) = re_bracket.captures(token) {
                if let Some(inner) = caps.get(1) {
                    types.insert(inner.as_str().to_string());
                }
            }
        }
    }

    // Write the sorted type names to a temporary file.
    let mut temp_file = NamedTempFile::new()?;
    for type_name in &types {
        writeln!(temp_file, "{}", type_name)?;
    }

    // Persist the temporary file so it won't be deleted when dropped.
    let temp_path: PathBuf = temp_file
        .into_temp_path()
        .keep()
        .expect("Failed to persist temporary file");
    Ok(temp_path.display().to_string())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: {} <swift_file>", args[0]);
        std::process::exit(1);
    }
    match extract_types_from_file(&args[1]) {
        Ok(path) => println!("{}", path),
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_extract_types_returns_empty_for_file_with_no_capitalized_words() -> Result<(), Box<dyn std::error::Error>> {
        // Create a temporary Swift file with no capitalized words.
        let mut swift_file = NamedTempFile::new()?;
        writeln!(swift_file, "import foundation\nlet x = 5")?;
        let result_path = extract_types_from_file(swift_file.path())?;
        let result = fs::read_to_string(&result_path)?;
        // Expect no types to be found.
        assert!(result.trim().is_empty());
        Ok(())
    }

    #[test]
    fn test_extract_types_extracts_capitalized_words() -> Result<(), Box<dyn std::error::Error>> {
        // Create a temporary Swift file with type declarations.
        let mut swift_file = NamedTempFile::new()?;
        writeln!(
            swift_file,
            "import Foundation
class MyClass {{}}
struct MyStruct {{}}
enum MyEnum {{}}"
        )?;
        let result_path = extract_types_from_file(swift_file.path())?;
        let result = fs::read_to_string(&result_path)?;
        // BTreeSet sorts alphabetically.
        let expected = "MyClass\nMyEnum\nMyStruct";
        assert_eq!(result.trim(), expected);
        Ok(())
    }

    #[test]
    fn test_extract_types_extracts_type_names_from_bracket_notation() -> Result<(), Box<dyn std::error::Error>> {
        // Create a Swift file using bracket notation.
        let mut swift_file = NamedTempFile::new()?;
        writeln!(swift_file, "import UIKit\nlet array: [CustomType] = []")?;
        let result_path = extract_types_from_file(swift_file.path())?;
        let result = fs::read_to_string(&result_path)?;
        assert_eq!(result.trim(), "CustomType");
        Ok(())
    }
}
