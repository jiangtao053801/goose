use goose_server::openapi;
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let schema = openapi::generate_schema();

    let package_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_path = PathBuf::from(package_dir)
        .join("..")
        .join("..")
        .join("ui")
        .join("desktop")
        .join("openapi.json");

    // Try to write schema file; non-fatal if permission denied
    if let Some(parent) = output_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    match fs::write(&output_path, format!("{schema}\n")) {
        Ok(()) => {
            eprintln!(
                "Successfully generated OpenAPI schema at {}",
                output_path.canonicalize().unwrap_or_else(|_| output_path.clone()).display()
            );
        }
        Err(e) => {
            eprintln!(
                "Warning: Could not write OpenAPI schema to {}: {}",
                output_path.display(),
                e
            );
        }
    }

    // Output the schema to stdout for piping
    println!("{}", schema);
}
