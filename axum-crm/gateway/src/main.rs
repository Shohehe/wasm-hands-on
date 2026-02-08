use axum::{
    body::Bytes,
    extract::{Query, State},
    http::{Method, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde::Deserialize;
use std::env;
use std::time::Instant;

#[derive(Clone)]
struct AppState {
    client: reqwest::Client,
    customer_service_url: String,
    order_service_url: String,
}

#[tokio::main]
async fn main() {
    let state = AppState {
        client: reqwest::Client::new(),
        customer_service_url: env::var("CUSTOMER_SERVICE_URL")
            .unwrap_or_else(|_| "http://localhost:8001".to_string()),
        order_service_url: env::var("ORDER_SERVICE_URL")
            .unwrap_or_else(|_| "http://localhost:8002".to_string()),
    };

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/compute", get(compute_handler))
        .fallback(proxy_handler)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

#[derive(Deserialize)]
struct ComputeParams {
    n: Option<u64>,
}

async fn healthz() -> impl IntoResponse {
    json_response(StatusCode::OK, r#"{"status":"ok"}"#)
}

async fn compute_handler(Query(params): Query<ComputeParams>) -> Response {
    let n = params.n.unwrap_or(1000);
    let t = Instant::now();
    let result = fibonacci(n);
    let compute_ms = t.elapsed().as_secs_f64() * 1000.0;
    let body = format!(
        r#"{{"n":{},"result":"{}","compute_ms":{:.3}}}"#,
        n, result, compute_ms
    );
    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/json")
        .header("server-timing", format!("compute;dur={:.3}", compute_ms))
        .body(axum::body::Body::from(body))
        .unwrap()
}

fn fibonacci(n: u64) -> u64 {
    if n <= 1 {
        return n;
    }
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        let tmp = a.wrapping_add(b);
        a = b;
        b = tmp;
    }
    b
}

async fn proxy_handler(
    State(state): State<AppState>,
    method: Method,
    uri: axum::http::Uri,
    body: Bytes,
) -> Response {
    let path = uri.path();

    let upstream_base = if path.starts_with("/customers") {
        &state.customer_service_url
    } else if path.starts_with("/orders") {
        &state.order_service_url
    } else {
        return json_response(StatusCode::NOT_FOUND, r#"{"error":"Not found"}"#);
    };

    let url = format!("{}{}", upstream_base, path);

    let resp = state
        .client
        .request(method, &url)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await;

    match resp {
        Ok(r) => {
            let status =
                StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            let server_timing = r
                .headers()
                .get("server-timing")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            let body = r.bytes().await.unwrap_or_default();
            let mut builder = Response::builder()
                .status(status)
                .header("content-type", "application/json");
            if let Some(timing) = &server_timing {
                builder = builder.header("server-timing", timing.as_str());
            }
            builder
                .body(axum::body::Body::from(body))
                .unwrap()
        }
        Err(e) => {
            let msg = format!(r#"{{"error":"Upstream unavailable: {}"}}"#, e);
            json_response(StatusCode::BAD_GATEWAY, &msg)
        }
    }
}

fn json_response(status: StatusCode, body: &str) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}
