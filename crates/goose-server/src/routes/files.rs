use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Multipart, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use goose::config::paths::Paths;
use std::path::PathBuf;
use std::sync::Arc;

use crate::state::AppState;

/// POST /upload — accept file, save to data/uploads/, return temp URL
async fn upload_file(
    State(_state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<Response, StatusCode> {
    let upload_dir = Paths::data_dir().join("uploads");
    tokio::fs::create_dir_all(&upload_dir)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mut uploaded: Vec<serde_json::Value> = vec![];

    while let Ok(Some(field)) = multipart.next_field().await {
        let file_name = field
            .file_name()
            .unwrap_or("unnamed")
            .to_string();
        let data = field
            .bytes()
            .await
            .map_err(|_| StatusCode::BAD_REQUEST)?;

        // Sanitize filename and add timestamp to avoid collisions
        let safe_name = sanitize_filename::sanitize(&file_name);
        let dest_name = format!(
            "{}_{}",
            chrono::Utc::now().format("%Y%m%d%H%M%S"),
            safe_name
        );
        let dest_path = upload_dir.join(&dest_name);

        tokio::fs::write(&dest_path, &data)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

        uploaded.push(serde_json::json!({
            "original_name": file_name,
            "saved_name": dest_name,
            "path": format!("/files/uploads/{}", dest_name),
            "size": data.len(),
        }));
    }

    if uploaded.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(serde_json::to_string(&serde_json::json!({
            "files": uploaded
        })).unwrap()))
        .unwrap())
}

/// GET /files/*path — serve uploaded/generated files from data directory
async fn download_file(
    Path(file_path): Path<String>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    // Prevent path traversal
    let safe = std::path::Path::new(&file_path);
    if safe.components().any(|c| match c {
        std::path::Component::ParentDir => true,
        _ => false,
    }) {
        return Err(StatusCode::FORBIDDEN);
    }

    let full_path = Paths::data_dir().join(&file_path);

    if !full_path.exists() {
        return Err(StatusCode::NOT_FOUND);
    }

    if !full_path.is_file() {
        return Err(StatusCode::NOT_FOUND);
    }

    let metadata = tokio::fs::metadata(&full_path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let mime = mime_guess::from_path(&full_path)
        .first_or_octet_stream();

    // Read the file
    let file_data = tokio::fs::read(&full_path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Check for range header
    let range_header = headers.get(header::RANGE);
    let (status, data, content_length) = if let Some(range_str) = range_header
        .and_then(|v| v.to_str().ok())
    {
        // Simple range: bytes=start-end
        let range = parse_range(range_str, file_data.len() as u64);
        let start = range.0 as usize;
        let end = range.1 as usize;
        (
            StatusCode::PARTIAL_CONTENT,
            file_data[start..=end].to_vec(),
            end - start + 1,
        )
    } else {
        let len = file_data.len();
        (StatusCode::OK, file_data, len)
    };

    Ok(Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, mime.to_string())
        .header(header::CONTENT_LENGTH, content_length)
        .header(
            header::CONTENT_DISPOSITION,
            format!("inline; filename=\"{}\"", safe.file_name().unwrap_or(std::ffi::OsStr::new("file")).to_string_lossy()),
        )
        .body(Body::from(data))
        .unwrap())
}

fn parse_range(range_str: &str, file_size: u64) -> (u64, u64) {
    let range_str = range_str.trim_start_matches("bytes=");
    let parts: Vec<&str> = range_str.split('-').collect();
    let start: u64 = parts[0].parse().unwrap_or(0);
    let end: u64 = if parts.len() > 1 && !parts[1].is_empty() {
        parts[1].parse().unwrap_or(file_size - 1)
    } else {
        file_size - 1
    };
    (start.min(file_size - 1), end.min(file_size - 1))
}

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route(
            "/upload",
            post(upload_file)
                .layer(DefaultBodyLimit::max(100 * 1024 * 1024)), // 100MB
        )
        .route("/files/{*path}", get(download_file))
        .with_state(state)
}
