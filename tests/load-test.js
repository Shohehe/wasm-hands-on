import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const customerListLatency = new Trend('customer_list_latency');
const customerCreateLatency = new Trend('customer_create_latency');
const orderCreateLatency = new Trend('order_create_latency');

// Mixed scenario uses separate metrics to avoid contaminating per-scenario results
const mixedReadLatency = new Trend('mixed_read_latency');
const mixedWriteLatency = new Trend('mixed_write_latency');

// Server-Timing breakdown metrics
const serverConn = new Trend('server_conn_ms');
const serverQuery = new Trend('server_query_ms');
const serverSer = new Trend('server_ser_ms');
const serverVerify = new Trend('server_verify_ms');

// Configuration via env vars
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

export const options = {
  scenarios: {
    // Scenario 1: Read-heavy (customer list)
    read_load: {
      executor: 'constant-vus',
      vus: 10,
      duration: '30s',
      exec: 'readScenario',
      tags: { scenario: 'read' },
    },
    // Scenario 2: Write (customer create)
    write_load: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      exec: 'writeScenario',
      startTime: '35s',
      tags: { scenario: 'write' },
    },
    // Scenario 3: Inter-service (order create = customer check + DB write)
    inter_service: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      exec: 'interServiceScenario',
      startTime: '70s',
      tags: { scenario: 'inter_service' },
    },
    // Scenario 4: Mixed workload (70% read / 30% write)
    mixed: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '10s', target: 10 },
        { duration: '30s', target: 20 },
        { duration: '10s', target: 0 },
      ],
      exec: 'mixedScenario',
      startTime: '105s',
      tags: { scenario: 'mixed' },
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<500'],
    'errors': ['rate<0.1'],
  },
};

function collectServerTiming(res) {
  const header = res.headers['Server-Timing'] || res.headers['server-timing'];
  if (!header) return;
  header.split(',').forEach(part => {
    const match = part.trim().match(/(\w+);dur=([\d.]+)/);
    if (match) {
      const name = match[1];
      const dur = parseFloat(match[2]);
      switch (name) {
        case 'conn': serverConn.add(dur); break;
        case 'query': serverQuery.add(dur); break;
        case 'ser': serverSer.add(dur); break;
        case 'verify': serverVerify.add(dur); break;
      }
    }
  });
}

// Setup: create a customer for order tests
export function setup() {
  const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
    name: 'Test Customer',
    email: 'test@example.com',
  }), { headers: { 'Content-Type': 'application/json' } });
  return { customerId: JSON.parse(res.body).id };
}

export function readScenario() {
  const start = Date.now();
  const res = http.get(`${BASE_URL}/customers`);
  customerListLatency.add(Date.now() - start);
  check(res, { 'read status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  collectServerTiming(res);
  sleep(0.1);
}

export function writeScenario() {
  const start = Date.now();
  const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
    name: `Customer ${Date.now()}`,
    email: `user${Date.now()}@example.com`,
  }), { headers: { 'Content-Type': 'application/json' } });
  customerCreateLatency.add(Date.now() - start);
  check(res, { 'write status 201': (r) => r.status === 201 });
  errorRate.add(res.status !== 201);
  collectServerTiming(res);
  sleep(0.1);
}

export function interServiceScenario(data) {
  const start = Date.now();
  const res = http.post(`${BASE_URL}/orders`, JSON.stringify({
    customer_id: data.customerId,
    product: `Product ${Date.now()}`,
    quantity: Math.floor(Math.random() * 10) + 1,
  }), { headers: { 'Content-Type': 'application/json' } });
  orderCreateLatency.add(Date.now() - start);
  check(res, { 'order status 201': (r) => r.status === 201 });
  errorRate.add(res.status !== 201);
  collectServerTiming(res);
  sleep(0.1);
}

export function mixedScenario(data) {
  if (Math.random() < 0.7) {
    const start = Date.now();
    const res = http.get(`${BASE_URL}/customers`);
    mixedReadLatency.add(Date.now() - start);
    check(res, { 'mixed read status 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    collectServerTiming(res);
    sleep(0.1);
  } else {
    const start = Date.now();
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
      name: `Customer ${Date.now()}`,
      email: `user${Date.now()}@example.com`,
    }), { headers: { 'Content-Type': 'application/json' } });
    mixedWriteLatency.add(Date.now() - start);
    check(res, { 'mixed write status 201': (r) => r.status === 201 });
    errorRate.add(res.status !== 201);
    collectServerTiming(res);
    sleep(0.1);
  }
}

export function handleSummary(data) {
  const out = {};
  const lines = ['\n=== CRUD Load Test Summary ==='];
  const metrics = Object.entries(data.metrics).sort((a, b) => a[0].localeCompare(b[0]));
  for (const [name, m] of metrics) {
    if (m.type === 'trend') {
      const v = m.values;
      lines.push(`  ${name}: avg=${v.avg.toFixed(2)} med=${v.med.toFixed(2)} p90=${v['p(90)'].toFixed(2)} p95=${v['p(95)'].toFixed(2)} max=${v.max.toFixed(2)}`);
    } else if (m.type === 'rate') {
      lines.push(`  ${name}: ${(m.values.rate * 100).toFixed(1)}%`);
    } else if (m.type === 'counter') {
      lines.push(`  ${name}: ${m.values.count} (${m.values.rate.toFixed(1)}/s)`);
    }
  }
  lines.push('==============================\n');
  out['stdout'] = lines.join('\n');
  if (__ENV.SUMMARY_JSON) {
    out[__ENV.SUMMARY_JSON] = JSON.stringify(data, null, 2);
  }
  return out;
}
