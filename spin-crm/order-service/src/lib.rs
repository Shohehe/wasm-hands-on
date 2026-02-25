use anyhow::Result;
use serde::{Deserialize, Serialize};
use spin_sdk::http::{IntoResponse, Method, Request, Response, send};
use spin_sdk::http_component;
use spin_sdk::pg4::{Connection, Decode, ParameterValue};
use spin_sdk::variables;
use std::time::Instant;

#[derive(Serialize, Deserialize)]
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

#[http_component]
async fn handle_request(req: Request) -> Result<impl IntoResponse> {
    let path = req.path().to_string();
    let method = req.method();

    if path == "/healthz" {
        return json_response(200, r#"{"status":"ok"}"#);
    }

    let t_conn = Instant::now();
    let conn = Connection::open(&variables::get("db_url")?)?;
    let conn_ms = t_conn.elapsed().as_secs_f64() * 1000.0;

    let (_, resource_id) = parse_path(&path);

    match (method, resource_id) {
        (&Method::Get, None) => list_orders(&conn, conn_ms),
        (&Method::Post, None) => create_order(&conn, conn_ms, req.body()).await,
        (&Method::Get, Some(id)) => get_order(&conn, conn_ms, id),
        _ => json_response(405, r#"{"error":"Method not allowed"}"#),
    }
}

fn parse_path(uri: &str) -> (&str, Option<&str>) {
    let path = uri.split('?').next().unwrap_or(uri);
    let path = path.trim_end_matches('/');
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() >= 3 && !parts[2].is_empty() {
        ("/orders", Some(parts[2]))
    } else {
        ("/orders", None)
    }
}

async fn verify_customer_exists(customer_id: i64) -> Result<bool> {
    let customer_url = variables::get("customer_service_url")?;
    let url = format!("{}/customers/{}", customer_url, customer_id);

    let outbound = Request::get(&url).build();
    let resp: Response = send(outbound).await?;
    Ok(*resp.status() == 200)
}

fn list_orders(conn: &Connection, conn_ms: f64) -> Result<Response> {
    let t_query = Instant::now();
    let rowset = conn.query(
        "SELECT id, customer_id, product, quantity FROM orders",
        &[],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let orders: Vec<Order> = rowset
        .rows
        .iter()
        .map(|row| Order {
            id: i64::decode(&row[0]).unwrap_or(0),
            customer_id: i64::decode(&row[1]).unwrap_or(0),
            product: String::decode(&row[2]).unwrap_or_default(),
            quantity: i64::decode(&row[3]).unwrap_or(0),
        })
        .collect();

    let t_ser = Instant::now();
    let body = serde_json::to_string(&orders)?;
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    timed_response(200, &body, conn_ms, query_ms, ser_ms)
}

async fn create_order(conn: &Connection, conn_ms: f64, body: &[u8]) -> Result<Response> {
    let body_str = std::str::from_utf8(body)?;
    let input: CreateOrderRequest = match serde_json::from_str(body_str) {
        Ok(v) => v,
        Err(_) => return json_response(400, r#"{"error":"Invalid JSON"}"#),
    };

    let customer_id = match input.customer_id {
        Some(id) if id > 0 => id,
        Some(_) => {
            return json_response(400, r#"{"error":"customer_id must be positive"}"#)
        }
        None => {
            return json_response(
                400,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };
    let product = match &input.product {
        Some(p) if !p.is_empty() && p.len() <= 255 => p.clone(),
        Some(p) if p.len() > 255 => {
            return json_response(400, r#"{"error":"product must be 255 characters or less"}"#)
        }
        _ => {
            return json_response(
                400,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };
    let quantity = match input.quantity {
        Some(q) if q > 0 => q,
        Some(_) => {
            return json_response(400, r#"{"error":"quantity must be positive"}"#)
        }
        None => {
            return json_response(
                400,
                r#"{"error":"customer_id, product, and quantity are required"}"#,
            )
        }
    };

    // Verify customer exists via Customer Service
    let t_verify = Instant::now();
    match verify_customer_exists(customer_id).await {
        Ok(true) => {}
        Ok(false) => return json_response(400, r#"{"error":"Customer not found"}"#),
        Err(_) => {
            return json_response(502, r#"{"error":"Customer service unavailable"}"#)
        }
    }
    let verify_ms = t_verify.elapsed().as_secs_f64() * 1000.0;

    let t_query = Instant::now();
    let rowset = conn.query(
        "INSERT INTO orders (customer_id, product, quantity) VALUES ($1, $2, $3) RETURNING id, customer_id, product, quantity",
        &[
            ParameterValue::Int64(customer_id),
            ParameterValue::Str(product),
            ParameterValue::Int64(quantity),
        ],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let order = rowset.rows.first().map(|row| Order {
        id: i64::decode(&row[0]).unwrap_or(0),
        customer_id: i64::decode(&row[1]).unwrap_or(0),
        product: String::decode(&row[2]).unwrap_or_default(),
        quantity: i64::decode(&row[3]).unwrap_or(0),
    });

    match order {
        Some(o) => {
            let t_ser = Instant::now();
            let body = serde_json::to_string(&o)?;
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            Ok(Response::builder()
                .status(201)
                .header("content-type", "application/json")
                .header(
                    "server-timing",
                    format!(
                        "conn;dur={:.1}, verify;dur={:.1}, query;dur={:.1}, ser;dur={:.1}",
                        conn_ms, verify_ms, query_ms, ser_ms
                    ),
                )
                .body(body)
                .build())
        }
        None => json_response(500, r#"{"error":"Failed to retrieve created order"}"#),
    }
}

fn get_order(conn: &Connection, conn_ms: f64, id_str: &str) -> Result<Response> {
    let id: i64 = match id_str.parse() {
        Ok(v) => v,
        Err(_) => return json_response(400, r#"{"error":"Invalid order ID"}"#),
    };

    let t_query = Instant::now();
    let rowset = conn.query(
        "SELECT id, customer_id, product, quantity FROM orders WHERE id = $1",
        &[ParameterValue::Int64(id)],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let order = rowset.rows.first().map(|row| Order {
        id: i64::decode(&row[0]).unwrap_or(0),
        customer_id: i64::decode(&row[1]).unwrap_or(0),
        product: String::decode(&row[2]).unwrap_or_default(),
        quantity: i64::decode(&row[3]).unwrap_or(0),
    });

    match order {
        Some(o) => {
            let t_ser = Instant::now();
            let body = serde_json::to_string(&o)?;
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            timed_response(200, &body, conn_ms, query_ms, ser_ms)
        }
        None => json_response(404, r#"{"error":"Order not found"}"#),
    }
}

fn json_response(status: u16, body: &str) -> Result<Response> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(body.to_owned())
        .build())
}

fn timed_response(
    status: u16,
    body: &str,
    conn_ms: f64,
    query_ms: f64,
    ser_ms: f64,
) -> Result<Response> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header(
            "server-timing",
            format!(
                "conn;dur={:.1}, query;dur={:.1}, ser;dur={:.1}",
                conn_ms, query_ms, ser_ms
            ),
        )
        .body(body.to_owned())
        .build())
}
