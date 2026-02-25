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
struct Customer {
    id: i64,
    name: String,
    email: String,
}

#[derive(Deserialize)]
struct CreateCustomerRequest {
    name: Option<String>,
    email: Option<String>,
}

#[tokio::main]
async fn main() {
    let database_url =
        env::var("DATABASE_URL").unwrap_or_else(|_| "postgres://crm:crm@localhost:5432/crm_containers".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect to database");

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/customers/ping", get(ping_db))
        .route("/customers", get(list_customers).post(create_customer))
        .route(
            "/customers/{id}",
            get(get_customer).delete(delete_customer),
        )
        .fallback(method_not_allowed)
        .with_state(pool);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8001")
        .await
        .expect("Failed to bind to port 8001");
    axum::serve(listener, app).await.expect("Server error");
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

async fn ping_db(State(pool): State<PgPool>) -> Response {
    let t_conn = Instant::now();
    let mut conn = match pool.acquire().await {
        Ok(c) => c,
        Err(_) => return db_error(),
    };
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    if let Err(_) = sqlx::query("SELECT 1").execute(&mut *conn).await {
        return db_error();
    }
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let body = format!(
        r#"{{"status":"ok","conn_ms":{:.3},"query_ms":{:.3}}}"#,
        conn_ms, query_ms
    );
    timed_response(StatusCode::OK, &body, conn_ms, query_ms, 0.0)
}

async fn list_customers(State(pool): State<PgPool>) -> Response {
    let t_conn = Instant::now();
    let mut conn = match pool.acquire().await {
        Ok(c) => c,
        Err(_) => return db_error(),
    };
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let customers: Vec<Customer> =
        match sqlx::query_as::<_, Customer>("SELECT id, name, email FROM customers")
            .fetch_all(&mut *conn)
            .await
        {
            Ok(v) => v,
            Err(_) => return db_error(),
        };
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let t_ser = Instant::now();
    let body = match serde_json::to_string(&customers) {
        Ok(s) => s,
        Err(_) => return db_error(),
    };
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    timed_response(StatusCode::OK, &body, conn_ms, query_ms, ser_ms)
}

async fn create_customer(State(pool): State<PgPool>, body: Bytes) -> Response {
    let input: CreateCustomerRequest = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return json_response(StatusCode::BAD_REQUEST, r#"{"error":"Invalid JSON"}"#),
    };

    let name = match &input.name {
        Some(n) if !n.is_empty() => n.clone(),
        _ => {
            return json_response(
                StatusCode::BAD_REQUEST,
                r#"{"error":"name and email are required"}"#,
            )
        }
    };
    let email = match &input.email {
        Some(e) if !e.is_empty() => e.clone(),
        _ => {
            return json_response(
                StatusCode::BAD_REQUEST,
                r#"{"error":"name and email are required"}"#,
            )
        }
    };

    if name.len() > 255 {
        return json_response(StatusCode::BAD_REQUEST, r#"{"error":"name must be 255 characters or less"}"#);
    }
    if email.len() > 255 || !email.contains('@') {
        return json_response(StatusCode::BAD_REQUEST, r#"{"error":"invalid email format"}"#);
    }

    let t_conn = Instant::now();
    let mut conn = match pool.acquire().await {
        Ok(c) => c,
        Err(_) => return db_error(),
    };
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let id: i64 =
        match sqlx::query_scalar("INSERT INTO customers (name, email) VALUES ($1, $2) RETURNING id")
            .bind(&name)
            .bind(&email)
            .fetch_one(&mut *conn)
            .await
        {
            Ok(v) => v,
            Err(_) => return db_error(),
        };
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let customer = Customer { id, name, email };

    let t_ser = Instant::now();
    let body = match serde_json::to_string(&customer) {
        Ok(s) => s,
        Err(_) => return db_error(),
    };
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    timed_response(StatusCode::CREATED, &body, conn_ms, query_ms, ser_ms)
}

async fn get_customer(State(pool): State<PgPool>, Path(id): Path<i64>) -> Response {
    let t_conn = Instant::now();
    let mut conn = match pool.acquire().await {
        Ok(c) => c,
        Err(_) => return db_error(),
    };
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let result =
        match sqlx::query_as::<_, Customer>("SELECT id, name, email FROM customers WHERE id = $1")
            .bind(id)
            .fetch_optional(&mut *conn)
            .await
        {
            Ok(v) => v,
            Err(_) => return db_error(),
        };
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    match result {
        Some(c) => {
            let t_ser = Instant::now();
            let body = match serde_json::to_string(&c) {
                Ok(s) => s,
                Err(_) => return db_error(),
            };
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            timed_response(StatusCode::OK, &body, conn_ms, query_ms, ser_ms)
        }
        None => json_response(StatusCode::NOT_FOUND, r#"{"error":"Customer not found"}"#),
    }
}

async fn delete_customer(State(pool): State<PgPool>, Path(id): Path<i64>) -> Response {
    let t_conn = Instant::now();
    let mut conn = match pool.acquire().await {
        Ok(c) => c,
        Err(_) => return db_error(),
    };
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let result = match sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(id)
        .execute(&mut *conn)
        .await
    {
        Ok(v) => v,
        Err(_) => return db_error(),
    };
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    if result.rows_affected() == 0 {
        return json_response(StatusCode::NOT_FOUND, r#"{"error":"Customer not found"}"#);
    }

    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .header(
            "server-timing",
            format!("conn;dur={:.1}, query;dur={:.1}", conn_ms, query_ms),
        )
        .body(axum::body::Body::empty())
        .unwrap()
}

fn db_error() -> Response {
    json_response(
        StatusCode::INTERNAL_SERVER_ERROR,
        r#"{"error":"Database error"}"#,
    )
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
