use regex::Regex;
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;
use walkdir::WalkDir;

/// Allowed file extensions.
const ALLOWED_EXTENSIONS: &[&str] = &["swift", "h", "m", "js"];

/// Mimics the behavior of get-search-roots.sh:
/// - If `root/Package.swift` exists, returns only that directory.
/// - Otherwise, returns the root (if not a ".build" directory) plus any subdirectories that contain Package.swift (excluding those inside ".build").
fn get_search_roots(root: &str) -> Vec<PathBuf> {
    let root_path = Path::new(root);
    let mut roots = Vec::new();

    if root_path.join("Package.swift").is_file() {
        roots.push(root_path.to_path_buf());
        return roots;
    }

    // If the basename is not ".build", add the root.
    if let Some(name) = root_path.file_name().and_then(|s| s.to_str()) {
        if name != ".build" {
            roots.push(root_path.to_path_buf());
        }
    } else {
        roots.push(root_path.to_path_buf());
    }

    // Walk for subdirectories containing Package.swift, excluding those in .build.
    for entry in WalkDir::new(root_path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        if entry.file_name() == "Package.swift" {
            let path_str = entry.path().to_string_lossy();
            if path_str.contains("/.build/") {
                continue;
            }
            if let Some(parent) = entry.path().parent() {
                roots.push(parent.to_path_buf());
            }
        }
    }

    roots.sort();
    roots.dedup();
    roots
}

/// Given a file path, returns true if the file’s extension is allowed
/// and its path does not contain "/.build/" or "/Pods/".
fn is_allowed_file(path: &Path) -> bool {
    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
        let ext_lower = ext.to_lowercase();
        if !ALLOWED_EXTENSIONS.contains(&ext_lower.as_str()) {
            return false;
        }
    } else {
        return false;
    }
    let path_str = path.to_string_lossy();
    !path_str.contains("/.build/") && !path_str.contains("/Pods/")
}

/// Reads the types file and joins its lines with "|" to build a regex fragment.
fn build_types_regex(types_file: &Path) -> io::Result<String> {
    let file = fs::File::open(types_file)?;
    let reader = BufReader::new(file);
    // Join each trimmed nonempty line with "|".
    let types: Vec<String> = reader
        .lines()
        .filter_map(|line| line.ok())
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect();
    Ok(types.join("|"))
}

fn main() -> io::Result<()> {
    // Expect exactly two arguments: <types_file> and <root>
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: {} <types_file> <root>", args[0]);
        std::process::exit(1);
    }
    let types_file = Path::new(&args[1]);
    let root = &args[2];

    // Verbose flag from environment.
    let verbose = env::var("VERBOSE").unwrap_or_else(|_| "false".to_string()) == "true";

    // Build the combined regex fragment from the types file.
    let types_regex_fragment = build_types_regex(types_file)?;
    if verbose {
        eprintln!("[VERBOSE] Combined types regex fragment: {}", types_regex_fragment);
    }

    // Build the final regex pattern.
    let pattern = format!(
        r"\b(?:class|struct|enum|protocol|typealias)\s+(?:{})\b",
        types_regex_fragment
    );
    let re = Regex::new(&pattern).map_err(|e| {
        eprintln!("Error compiling regex: {}", e);
        io::Error::new(io::ErrorKind::Other, e)
    })?;
    if verbose {
        eprintln!("[VERBOSE] Final regex pattern: {}", pattern);
    }

    // Get search roots using our helper function.
    let search_roots = get_search_roots(root);
    if verbose {
        eprintln!(
            "[VERBOSE] Search roots ({}):",
            search_roots.len()
        );
        for sr in &search_roots {
            eprintln!("  - {}", sr.display());
        }
    }

    // Use a BTreeSet to deduplicate matching file paths.
    let mut found_files = BTreeSet::new();

    // For each search root, walk the directory tree.
    for sr in search_roots {
        if verbose {
            eprintln!("[VERBOSE] Searching in directory: {}", sr.display());
        }
        for entry in WalkDir::new(&sr)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
        {
            let path = entry.path();
            if !is_allowed_file(path) {
                continue;
            }
            // Read file content. If reading fails, skip this file.
            let content = fs::read_to_string(path).unwrap_or_default();
            if re.is_match(&content) {
                found_files.insert(path.to_path_buf());
                if verbose {
                    eprintln!("  [VERBOSE] Matched: {}", path.display());
                }
            }
        }
        if verbose {
            eprintln!("[VERBOSE] Completed search in directory: {}", sr.display());
        }
    }

    if verbose {
        eprintln!(
            "[VERBOSE] Total unique files found: {}",
            found_files.len()
        );
    }

    // Write the deduplicated list of file paths to a temporary file.
    let mut temp_file = NamedTempFile::new()?;
    for file_path in &found_files {
        writeln!(temp_file, "{}", file_path.display())?;
    }
    // Persist the temporary file (i.e. prevent deletion on drop) and print its path.
    let temp_path = temp_file.into_temp_path().keep()?;
    println!("{}", temp_path.display());

    Ok(())
}
