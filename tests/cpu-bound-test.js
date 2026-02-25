import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const serverCompute = new Trend('server_compute_ms');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
const N = __ENV.N || '1000';

export const options = {
  scenarios: {
    cpu_bound: {
      executor: 'constant-vus',
      vus: 10,
      duration: '30s',
      exec: 'computeScenario',
      tags: { scenario: 'cpu_bound' },
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
  const match = header.match(/compute;dur=([\d.]+)/);
  if (match) {
    serverCompute.add(parseFloat(match[1]));
  }
}

export function computeScenario() {
  const res = http.get(`${BASE_URL}/compute?n=${N}`);
  check(res, { 'compute status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  collectServerTiming(res);
  sleep(0.1);
}

export function handleSummary(data) {
  const out = {};
  const lines = ['\n=== CPU Bound Test Summary ==='];
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
