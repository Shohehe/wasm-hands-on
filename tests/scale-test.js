import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const requestLatency = new Trend('request_latency');
const serverConn = new Trend('server_conn_ms');
const serverQuery = new Trend('server_query_ms');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

// Scalability test: ramp from 1 to 50 VUs to find throughput limits
export const options = {
  scenarios: {
    scale_ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '15s', target: 5 },
        { duration: '15s', target: 10 },
        { duration: '15s', target: 20 },
        { duration: '15s', target: 50 },
        { duration: '15s', target: 100 },
        { duration: '15s', target: 0 },
      ],
      exec: 'scaleScenario',
      tags: { scenario: 'scale_ramp' },
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<1000'],
    'errors': ['rate<0.2'],
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
      }
    }
  });
}

// Setup: create a customer so we have data to read
export function setup() {
  const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
    name: 'Scale Test Customer',
    email: 'scale@example.com',
  }), { headers: { 'Content-Type': 'application/json' } });
  return { customerId: JSON.parse(res.body).id };
}

export function scaleScenario() {
  // 80% reads, 20% writes to simulate realistic load
  if (Math.random() < 0.8) {
    const start = Date.now();
    const res = http.get(`${BASE_URL}/customers`);
    requestLatency.add(Date.now() - start);
    check(res, { 'scale read 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    collectServerTiming(res);
  } else {
    const start = Date.now();
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
      name: `Scale ${Date.now()}`,
      email: `s${Date.now()}@example.com`,
    }), { headers: { 'Content-Type': 'application/json' } });
    requestLatency.add(Date.now() - start);
    check(res, { 'scale write 201': (r) => r.status === 201 });
    errorRate.add(res.status !== 201);
    collectServerTiming(res);
  }
  sleep(0.05);
}

export function handleSummary(data) {
  const out = {};

  // Text summary
  const lines = ['\n=== Scalability Test Summary ==='];
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
  lines.push('================================\n');
  out['stdout'] = lines.join('\n');

  if (__ENV.SUMMARY_JSON) {
    out[__ENV.SUMMARY_JSON] = JSON.stringify(data, null, 2);
  }

  return out;
}
