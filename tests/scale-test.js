import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics per VU level
const errorRate = new Rate('errors');
const requestLatency = new Trend('request_latency');
const serverConn = new Trend('server_conn_ms');
const serverQuery = new Trend('server_query_ms');

// Per-VU-level latency trends
const latency_5vu = new Trend('latency_5vu');
const latency_10vu = new Trend('latency_10vu');
const latency_20vu = new Trend('latency_20vu');
const latency_50vu = new Trend('latency_50vu');
const latency_100vu = new Trend('latency_100vu');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

// Scalability test: independent constant-vus scenarios per VU level
// This allows clear per-level performance comparison without ramping ambiguity
export const options = {
  scenarios: {
    scale_5vu: {
      executor: 'constant-vus',
      vus: 5,
      duration: '15s',
      exec: 'scale5',
      tags: { vu_level: '5' },
    },
    scale_10vu: {
      executor: 'constant-vus',
      vus: 10,
      duration: '15s',
      exec: 'scale10',
      startTime: '18s',
      tags: { vu_level: '10' },
    },
    scale_20vu: {
      executor: 'constant-vus',
      vus: 20,
      duration: '15s',
      exec: 'scale20',
      startTime: '36s',
      tags: { vu_level: '20' },
    },
    scale_50vu: {
      executor: 'constant-vus',
      vus: 50,
      duration: '15s',
      exec: 'scale50',
      startTime: '54s',
      tags: { vu_level: '50' },
    },
    scale_100vu: {
      executor: 'constant-vus',
      vus: 100,
      duration: '15s',
      exec: 'scale100',
      startTime: '72s',
      tags: { vu_level: '100' },
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

// Setup: create a customer so we have a known ID for reads
export function setup() {
  const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
    name: 'Scale Test Customer',
    email: 'scale@example.com',
  }), { headers: { 'Content-Type': 'application/json' } });
  const body = JSON.parse(res.body);
  return { customerId: body.id };
}

// Core scenario logic: 80% reads (by ID), 20% writes
function runScale(data, latencyTrend) {
  if (Math.random() < 0.8) {
    const start = Date.now();
    const res = http.get(`${BASE_URL}/customers/${data.customerId}`);
    const elapsed = Date.now() - start;
    requestLatency.add(elapsed);
    latencyTrend.add(elapsed);
    check(res, { 'scale read 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    collectServerTiming(res);
  } else {
    const start = Date.now();
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
      name: `Scale ${Date.now()}`,
      email: `s${Date.now()}@example.com`,
    }), { headers: { 'Content-Type': 'application/json' } });
    const elapsed = Date.now() - start;
    requestLatency.add(elapsed);
    latencyTrend.add(elapsed);
    check(res, { 'scale write 201': (r) => r.status === 201 });
    errorRate.add(res.status !== 201);
    collectServerTiming(res);
  }
  sleep(0.05);
}

export function scale5(data) { runScale(data, latency_5vu); }
export function scale10(data) { runScale(data, latency_10vu); }
export function scale20(data) { runScale(data, latency_20vu); }
export function scale50(data) { runScale(data, latency_50vu); }
export function scale100(data) { runScale(data, latency_100vu); }

export function handleSummary(data) {
  const out = {};

  // Text summary
  const lines = ['\n=== Scalability Test Summary ==='];

  // Per-VU-level breakdown
  const vuLevels = [5, 10, 20, 50, 100];
  lines.push('\n--- Per VU Level ---');
  for (const vu of vuLevels) {
    const key = `latency_${vu}vu`;
    const m = data.metrics[key];
    if (m && m.values) {
      const v = m.values;
      lines.push(`  ${vu} VUs: avg=${v.avg.toFixed(2)} med=${v.med.toFixed(2)} p90=${v['p(90)'].toFixed(2)} p95=${v['p(95)'].toFixed(2)} max=${v.max.toFixed(2)} count=${v.count}`);
    }
  }

  // Overall metrics
  lines.push('\n--- Overall ---');
  const metrics = Object.entries(data.metrics).sort((a, b) => a[0].localeCompare(b[0]));
  for (const [name, m] of metrics) {
    // Skip per-VU metrics (already shown above)
    if (name.match(/^latency_\d+vu$/)) continue;
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
