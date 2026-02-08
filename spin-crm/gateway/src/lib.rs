use anyhow::Result;
use spin_sdk::http::{IntoResponse, Request, Response, send};
use spin_sdk::http_component;
use spin_sdk::variables;
use std::time::Instant;

#[http_component]
async fn handle_request(req: Request) -> Result<impl IntoResponse> {
    let path = req.path().to_string();
    let full_uri = req.uri().to_string();

    if path == "/healthz" {
        return json_response(200, r#"{"status":"ok"}"#);
    }

    if path == "/compute" {
        let n = parse_query_param(&full_uri, "n").unwrap_or(1000);
        let t = Instant::now();
        let result = fibonacci(n);
        let compute_ms = t.elapsed().as_secs_f64() * 1000.0;
        let body = format!(r#"{{"n":{},"result":"{}","compute_ms":{:.3}}}"#, n, result, compute_ms);
        return Ok(Response::builder()
            .status(200)
            .header("content-type", "application/json")
            .header("server-timing", format!("compute;dur={:.3}", compute_ms))
            .body(body)
            .build());
    }

    let customer_url = variables::get("customer_service_url")?;
    let order_url = variables::get("order_service_url")?;

    let upstream_base = if path.starts_with("/customers") {
        customer_url
    } else if path.starts_with("/orders") {
        order_url
    } else {
        return json_response(404, r#"{"error":"Not found"}"#);
    };

    let upstream_url = format!("{}{}", upstream_base, path);
    let method = req.method().clone();
    let body = req.body().to_vec();

    let outbound = Request::builder()
        .method(method)
        .uri(&upstream_url)
        .header("content-type", "application/json")
        .body(body)
        .build();

    let resp: Response = match send(outbound).await {
        Ok(r) => r,
        Err(e) => {
            let msg = format!(r#"{{"error":"Upstream unavailable: {}"}}"#, e);
            return json_response(502, &msg);
        }
    };

    let status = *resp.status();
    let timing: Option<String> = resp
        .headers()
        .find(|(name, _)| name.eq_ignore_ascii_case("server-timing"))
        .and_then(|(_, value)| value.as_str().map(|s| s.to_string()));
    let body = resp.into_body();
    match timing {
        Some(t) => Ok(Response::builder()
            .status(status)
            .header("content-type", "application/json")
            .header("server-timing", &t)
            .body(body)
            .build()),
        None => Ok(Response::builder()
            .status(status)
            .header("content-type", "application/json")
            .body(body)
            .build()),
    }
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

fn parse_query_param(uri: &str, key: &str) -> Option<u64> {
    let query = uri.split('?').nth(1)?;
    for pair in query.split('&') {
        let mut kv = pair.splitn(2, '=');
        if kv.next()? == key {
            return kv.next()?.parse().ok();
        }
    }
    None
}

fn json_response(status: u16, body: &str) -> Result<Response> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(body.to_owned())
        .build())
}
