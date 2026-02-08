use axum::{
    body::Bytes,
    extract::{Path, State},
    http::StatusCode,
    response::Response,
    routing::get,
    Router,
};
use serde::{Deserialize, Serialize};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::env;
use std::time::Instant;

#[derive(Serialize, Deserialize, sqlx::FromRow)]
struct Order {
    id: i64,
    customer_id: i64,
    product: String,
    quantity: i64,
}

#[derive(Deserialize)]
struct CreateOrderRequest {
    customer_id: Option<i64>,
    product: Option<String>,
    quantity: Option<i64>,
}

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    client: reqwest::Client,
    customer_service_url: String,
}

#[tokio::main]
async fn main() {
    let database_url =
        env::var("DATABASE_URL").unwrap_or_else(|_| "postgres://crm:crm@localhost:5432/crm_containers".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .unwrap();

    let state = AppState {
        pool,
        client: reqwest::Client::new(),
        customer_service_url: env::var("CUSTOMER_SERVICE_URL")
            .unwrap_or_else(|_| "http://localhost:8001".to_string()),
    };

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/orders", get(list_orders).post(create_order))
        .route("/orders/{id}", get(get_order))
        .fallback(method_not_allowed)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8002").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn healthz() -> Response {
    json_response(StatusCode::OK, r#"{"status":"ok"}"#)
}

async fn method_not_allowed() -> Response {
    json_response(
        StatusCode::METHOD_NOT_ALLOWED,
        r#"{"error":"Method not allowed"}"#,
    )
}

async fn list_orders(State(state): State<AppState>) -> Response {
    let t_conn = Instant::now();
    let mut conn = state.pool.acquire().await.unwrap();
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let orders: Vec<Order> =
        sqlx::query_as::<_, Order>("SELECT id, customer_id, product, quantity FROM orders")
            .fetch_all(&mut *conn)
            .await
            .unwrap();
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let t_ser = Instant::now();
    let body = serde_json::to_string(&orders).unwrap();
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    timed_response(StatusCode::OK, &body, conn_ms, query_ms, ser_ms)
}

async fn create_order(State(state): State<AppState>, body: Bytes) -> Response {
    let input: CreateOrderRequest = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return json_response(StatusCode::BAD_REQUEST, r#"{"error":"Invalid JSON"}"#),
    };

    let customer_id = match input.customer_id {
        Some(id) => id,
        None => {
            return json_response(
                StatusCode::BAD_REQUEST,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };
    let product = match &input.product {
        Some(p) if !p.is_empty() => p.clone(),
        _ => {
            return json_response(
                StatusCode::BAD_REQUEST,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };
    let quantity = match input.quantity {
        Some(q) => q,
        None => {
            return json_response(
                StatusCode::BAD_REQUEST,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };

    // Verify customer exists via Customer Service
    let t_verify = Instant::now();
    let url = format!(
        "{}/customers/{}",
        state.customer_service_url, customer_id
    );
    match state.client.get(&url).send().await {
        Ok(resp) if resp.status() == reqwest::StatusCode::OK => {}
        Ok(_) => {
            return json_response(StatusCode::BAD_REQUEST, r#"{"error":"Customer not found"}"#)
        }
        Err(_) => {
            return json_response(
                StatusCode::BAD_GATEWAY,
                r#"{"error":"Customer service unavailable"}"#,
            )
        }
    }
    let verify_ms = t_verify.elapsed().as_secs_f64() * 1000.0;

    let t_conn = Instant::now();
    let mut conn = state.pool.acquire().await.unwrap();
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let id: i64 = sqlx::query_scalar(
        "INSERT INTO orders (customer_id, product, quantity) VALUES ($1, $2, $3) RETURNING id",
    )
    .bind(customer_id)
    .bind(&product)
    .bind(quantity)
    .fetch_one(&mut *conn)
    .await
    .unwrap();
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let order = Order {
        id,
        customer_id,
        product,
        quantity,
    };

    let t_ser = Instant::now();
    let body = serde_json::to_string(&order).unwrap();
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    Response::builder()
        .status(StatusCode::CREATED)
        .header("content-type", "application/json")
        .header(
            "server-timing",
            format!(
                "conn;dur={:.1}, verify;dur={:.1}, query;dur={:.1}, ser;dur={:.1}",
                conn_ms, verify_ms, query_ms, ser_ms
            ),
        )
        .body(axum::body::Body::from(body))
        .unwrap()
}

async fn get_order(State(state): State<AppState>, Path(id): Path<i64>) -> Response {
    let t_conn = Instant::now();
    let mut conn = state.pool.acquire().await.unwrap();
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let result = sqlx::query_as::<_, Order>(
        "SELECT id, customer_id, product, quantity FROM orders WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&mut *conn)
    .await
    .unwrap();
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    match result {
        Some(o) => {
            let t_ser = Instant::now();
            let body = serde_json::to_string(&o).unwrap();
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            timed_response(StatusCode::OK, &body, conn_ms, query_ms, ser_ms)
        }
        None => json_response(StatusCode::NOT_FOUND, r#"{"error":"Order not found"}"#),
    }
}

fn json_response(status: StatusCode, body: &str) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}

fn timed_response(
    status: StatusCode,
    body: &str,
    conn_ms: f64,
    query_ms: f64,
    ser_ms: f64,
) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header(
            "server-timing",
            format!(
                "conn;dur={:.1}, query;dur={:.1}, ser;dur={:.1}",
                conn_ms, query_ms, ser_ms
            ),
        )
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}
