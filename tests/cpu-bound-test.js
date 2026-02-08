import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const computeLatency = new Trend('compute_latency');
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
  const start = Date.now();
  const res = http.get(`${BASE_URL}/compute?n=${N}`);
  computeLatency.add(Date.now() - start);
  check(res, { 'compute status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  collectServerTiming(res);
  sleep(0.1);
}
