import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const pingLatency = new Trend('ping_latency');
const serverConn = new Trend('server_conn_ms');
const serverQuery = new Trend('server_query_ms');

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

export const options = {
  scenarios: {
    ping_db: {
      executor: 'constant-vus',
      vus: 10,
      duration: '30s',
      exec: 'pingScenario',
      tags: { scenario: 'ping_db' },
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
      }
    }
  });
}

export function pingScenario() {
  const start = Date.now();
  const res = http.get(`${BASE_URL}/customers/ping`);
  pingLatency.add(Date.now() - start);
  check(res, { 'ping status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  collectServerTiming(res);
  sleep(0.1);
}
