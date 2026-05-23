pub mod action_required;
pub mod agent;
pub mod config_management;
pub mod dictation;
pub mod errors;
pub mod features;
pub mod gateway;
#[cfg(feature = "local-inference")]
pub mod local_inference;
pub mod mcp_app_proxy;
pub mod mcp_ui_proxy;
pub mod prompts;
pub mod recipe;
pub mod recipe_utils;
pub mod reply;
pub mod sampling;
pub mod schedule;
pub mod session;
pub mod session_events;
pub mod setup;
pub mod status;
pub mod telemetry;
pub mod tunnel;
pub mod utils;

use std::sync::Arc;

use axum::{
    extract::Request,
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    Router,
};

// Function to configure all routes
pub fn configure(state: Arc<crate::state::AppState>, secret_key: String) -> Router {
    async fn require_local_admin(request: Request, next: Next) -> Result<Response, StatusCode> {
        let is_remote = request
            .headers()
            .get("x-client-id")
            .and_then(|v| v.to_str().ok())
            .map(|v| !v.is_empty())
            .unwrap_or(false);

        if is_remote {
            Err(StatusCode::FORBIDDEN)
        } else {
            Ok(next.run(request).await)
        }
    }

    let admin_layer = middleware::from_fn(require_local_admin);

    let router = Router::new()
        .merge(status::routes(state.clone()))
        .merge(reply::routes(state.clone()))
        .merge(action_required::routes(state.clone()))
        .merge(agent::routes(state.clone()))
        .merge(config_management::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(prompts::routes())
        .merge(recipe::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(session::routes(state.clone()))
        .merge(schedule::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(setup::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(telemetry::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(tunnel::routes(state.clone()))
        .merge(gateway::routes(state.clone()).route_layer(admin_layer.clone()))
        .merge(mcp_ui_proxy::routes(secret_key.clone()))
        .merge(mcp_app_proxy::routes(secret_key))
        .merge(session_events::routes(state.clone()))
        .merge(sampling::routes(state.clone()))
        .merge(dictation::routes(state.clone()))
        .merge(features::routes());

    #[cfg(feature = "local-inference")]
    let router = router.merge(local_inference::routes(state).route_layer(admin_layer));

    router
}
