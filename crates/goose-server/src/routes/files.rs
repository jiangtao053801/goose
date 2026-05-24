use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Multipart, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use goose::config::paths::Paths;
use std::sync::Arc;

use crate::state::AppState;

/// POST /upload — accept file, save to data/uploads/{client_id}/{session_id}/, return URL
async fn upload_file(
    State(_state): State<Arc<AppState>>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Response, StatusCode> {
    // Extract client_id and session_id from headers
    let client_id = headers
        .get("X-Client-Id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown");
    let session_id = headers
        .get("X-Session-Id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown");

    // Sanitize path segments
    let safe_client = sanitize_filename::sanitize(client_id);
    let safe_session = sanitize_filename::sanitize(session_id);

    let upload_dir = Paths::data_dir()
        .join("uploads")
        .join(&safe_client)
        .join(&safe_session);

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

        let content_type = field
            .content_type()
            .map(|s| s.to_string())
            .unwrap_or_else(|| mime_guess::from_path(&file_name).first_or_octet_stream().to_string());

        // Sanitize filename and add timestamp to avoid collisions
        let safe_name = sanitize_filename::sanitize(&file_name);
        let now = chrono::Utc::now();
        let dest_name = format!(
            "{}_{}",
            now.format("%Y%m%d%H%M%S"),
            safe_name
        );
        let dest_path = upload_dir.join(&dest_name);

        tokio::fs::write(&dest_path, &data)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

        // Human-readable size
        let size_human = if data.len() < 1024 {
            format!("{} B", data.len())
        } else if data.len() < 1024 * 1024 {
            format!("{:.1} KB", data.len() as f64 / 1024.0)
        } else {
            format!("{:.1} MB", data.len() as f64 / (1024.0 * 1024.0))
        };

        uploaded.push(serde_json::json!({
            "original_name": file_name,
            "saved_name": dest_name,
            "path": format!("/files/uploads/{}/{}/{}", safe_client, safe_session, dest_name),
            "size": data.len(),
            "size_human": size_human,
            "mime": content_type,
            "client_id": safe_client,
            "session_id": safe_session,
            "server_abs_path": dest_path.to_string_lossy(),
            "uploaded_at": now.to_rfc3339(),
        }));
    }

    if uploaded.is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(serde_json::to_string(&serde_json::json!({
            "files": uploaded,
            "storage": {
                "root": Paths::data_dir().join("uploads").to_string_lossy(),
                "structure": "uploads/{client_id}/{session_id}/{timestamp}_{filename}",
                "access_url": "/files/uploads/{client_id}/{session_id}/{timestamp}_{filename}"
            }
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

    let mime = mime_guess::from_path(&full_path)
        .first_or_octet_stream();

    let file_data = tokio::fs::read(&full_path)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Check for range header (supports video seeking, large file partial download)
    let range_header = headers.get(header::RANGE);
    let (status, data, content_length) = if let Some(range_str) = range_header
        .and_then(|v| v.to_str().ok())
    {
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
