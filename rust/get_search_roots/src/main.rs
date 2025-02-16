use std::env;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;
use std::collections::BTreeSet;

fn main() {
    // Expect exactly one argument: the root directory.
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: {} <git_root_or_package_root>", args[0]);
        std::process::exit(1);
    }
    let root = &args[1];
    let root_path = Path::new(root);

    // If the root itself is a Swift package (contains Package.swift), print it and exit.
    if root_path.join("Package.swift").is_file() {
        println!("{}", root);
        return;
    }

    // Otherwise, print the root if it is not a ".build" directory.
    if let Some(basename) = root_path.file_name().and_then(|s| s.to_str()) {
        if basename != ".build" {
            println!("{}", root);
        }
    } else {
        // Fallback: print the root if we cannot determine its basename.
        println!("{}", root);
    }

    // Now, find any subdirectories that contain Package.swift but exclude those inside .build folders.
    let mut found_dirs = BTreeSet::new();
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
            if let Some(dir) = entry.path().parent() {
                found_dirs.insert(dir.to_path_buf());
            }
        }
    }

    // Print the unique directories (BTreeSet ensures sorted order).
    for dir in found_dirs {
        if let Some(s) = dir.to_str() {
            println!("{}", s);
        }
    }
}
