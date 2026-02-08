use anyhow::Result;
use serde::{Deserialize, Serialize};
use spin_sdk::http::{IntoResponse, Method, Request, Response};
use spin_sdk::http_component;
use spin_sdk::pg4::{Connection, Decode, ParameterValue};
use spin_sdk::variables;
use std::time::Instant;

#[derive(Serialize, Deserialize)]
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

#[http_component]
fn handle_request(req: Request) -> Result<impl IntoResponse> {
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
        (&Method::Get, Some("ping")) => ping_db(&conn, conn_ms),
        (&Method::Get, None) => list_customers(&conn, conn_ms),
        (&Method::Post, None) => create_customer(&conn, conn_ms, req.body()),
        (&Method::Get, Some(id)) => get_customer(&conn, conn_ms, id),
        (&Method::Delete, Some(id)) => delete_customer(&conn, conn_ms, id),
        _ => json_response(405, r#"{"error":"Method not allowed"}"#),
    }
}

fn parse_path(uri: &str) -> (&str, Option<&str>) {
    let path = uri.split('?').next().unwrap_or(uri);
    let path = path.trim_end_matches('/');
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() >= 3 && !parts[2].is_empty() {
        ("/customers", Some(parts[2]))
    } else {
        ("/customers", None)
    }
}

fn ping_db(conn: &Connection, conn_ms: f64) -> Result<Response> {
    let t_query = Instant::now();
    conn.query("SELECT 1", &[])?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let body = format!(
        r#"{{"status":"ok","conn_ms":{:.3},"query_ms":{:.3}}}"#,
        conn_ms, query_ms
    );
    timed_response(200, &body, conn_ms, query_ms, 0.0)
}

fn list_customers(conn: &Connection, conn_ms: f64) -> Result<Response> {
    let t_query = Instant::now();
    let rowset = conn.query("SELECT id, name, email FROM customers", &[])?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let customers: Vec<Customer> = rowset
        .rows
        .iter()
        .map(|row| Customer {
            id: i64::decode(&row[0]).unwrap_or(0),
            name: String::decode(&row[1]).unwrap_or_default(),
            email: String::decode(&row[2]).unwrap_or_default(),
        })
        .collect();

    let t_ser = Instant::now();
    let body = serde_json::to_string(&customers)?;
    let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;

    timed_response(200, &body, conn_ms, query_ms, ser_ms)
}

fn create_customer(conn: &Connection, conn_ms: f64, body: &[u8]) -> Result<Response> {
    let body_str = std::str::from_utf8(body)?;
    let input: CreateCustomerRequest = match serde_json::from_str(body_str) {
        Ok(v) => v,
        Err(_) => return json_response(400, r#"{"error":"Invalid JSON"}"#),
    };

    let name = match &input.name {
        Some(n) if !n.is_empty() => n.clone(),
        _ => return json_response(400, r#"{"error":"name and email are required"}"#),
    };
    let email = match &input.email {
        Some(e) if !e.is_empty() => e.clone(),
        _ => return json_response(400, r#"{"error":"name and email are required"}"#),
    };

    let t_query = Instant::now();
    let rowset = conn.query(
        "INSERT INTO customers (name, email) VALUES ($1, $2) RETURNING id, name, email",
        &[ParameterValue::Str(name), ParameterValue::Str(email)],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let customer = rowset.rows.first().map(|row| Customer {
        id: i64::decode(&row[0]).unwrap_or(0),
        name: String::decode(&row[1]).unwrap_or_default(),
        email: String::decode(&row[2]).unwrap_or_default(),
    });

    match customer {
        Some(c) => {
            let t_ser = Instant::now();
            let body = serde_json::to_string(&c)?;
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            timed_response(201, &body, conn_ms, query_ms, ser_ms)
        }
        None => json_response(500, r#"{"error":"Failed to retrieve created customer"}"#),
    }
}

fn get_customer(conn: &Connection, conn_ms: f64, id_str: &str) -> Result<Response> {
    let id: i64 = match id_str.parse() {
        Ok(v) => v,
        Err(_) => return json_response(400, r#"{"error":"Invalid customer ID"}"#),
    };

    let t_query = Instant::now();
    let rowset = conn.query(
        "SELECT id, name, email FROM customers WHERE id = $1",
        &[ParameterValue::Int64(id)],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    let customer = rowset.rows.first().map(|row| Customer {
        id: i64::decode(&row[0]).unwrap_or(0),
        name: String::decode(&row[1]).unwrap_or_default(),
        email: String::decode(&row[2]).unwrap_or_default(),
    });

    match customer {
        Some(c) => {
            let t_ser = Instant::now();
            let body = serde_json::to_string(&c)?;
            let ser_ms = t_ser.elapsed().as_secs_f64() * 1000.0;
            timed_response(200, &body, conn_ms, query_ms, ser_ms)
        }
        None => json_response(404, r#"{"error":"Customer not found"}"#),
    }
}

fn delete_customer(conn: &Connection, conn_ms: f64, id_str: &str) -> Result<Response> {
    let id: i64 = match id_str.parse() {
        Ok(v) => v,
        Err(_) => return json_response(400, r#"{"error":"Invalid customer ID"}"#),
    };

    let t_query = Instant::now();
    let rowset = conn.query(
        "SELECT id FROM customers WHERE id = $1",
        &[ParameterValue::Int64(id)],
    )?;

    if rowset.rows.is_empty() {
        return json_response(404, r#"{"error":"Customer not found"}"#);
    }

    conn.execute(
        "DELETE FROM customers WHERE id = $1",
        &[ParameterValue::Int64(id)],
    )?;
    let query_ms = t_query.elapsed().as_secs_f64() * 1000.0;

    Ok(Response::builder()
        .status(204)
        .header(
            "server-timing",
            format!("conn;dur={:.1}, query;dur={:.1}", conn_ms, query_ms),
        )
        .build())
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
