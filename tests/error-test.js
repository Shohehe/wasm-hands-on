import http from 'k6/http';
import { check, group } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('unexpected_errors');
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

export const options = {
  scenarios: {
    error_paths: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      exec: 'errorPathScenario',
    },
  },
};

export function errorPathScenario() {
  group('Invalid JSON', () => {
    const res = http.post(`${BASE_URL}/customers`, 'not-json', {
      headers: { 'Content-Type': 'application/json' },
    });
    check(res, {
      'invalid JSON returns 400': (r) => r.status === 400,
      'error message present': (r) => JSON.parse(r.body).error !== undefined,
    });
    errorRate.add(res.status !== 400);
  });

  group('Missing required fields', () => {
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({}), {
      headers: { 'Content-Type': 'application/json' },
    });
    check(res, {
      'missing fields returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Empty name', () => {
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
      name: '',
      email: 'test@example.com',
    }), { headers: { 'Content-Type': 'application/json' } });
    check(res, {
      'empty name returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Invalid email (no @)', () => {
    const res = http.post(`${BASE_URL}/customers`, JSON.stringify({
      name: 'Test',
      email: 'invalid-email',
    }), { headers: { 'Content-Type': 'application/json' } });
    check(res, {
      'invalid email returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Customer not found (GET)', () => {
    const res = http.get(`${BASE_URL}/customers/999999`);
    check(res, {
      'missing customer returns 404': (r) => r.status === 404,
    });
    errorRate.add(res.status !== 404);
  });

  group('Customer not found (DELETE)', () => {
    const res = http.del(`${BASE_URL}/customers/999999`);
    check(res, {
      'delete missing returns 404': (r) => r.status === 404,
    });
    errorRate.add(res.status !== 404);
  });

  group('Invalid customer ID', () => {
    const res = http.get(`${BASE_URL}/customers/not-a-number`);
    check(res, {
      'invalid ID returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Order with invalid customer', () => {
    const res = http.post(`${BASE_URL}/orders`, JSON.stringify({
      customer_id: 999999,
      product: 'Test Product',
      quantity: 1,
    }), { headers: { 'Content-Type': 'application/json' } });
    check(res, {
      'order with bad customer returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Order with zero quantity', () => {
    const res = http.post(`${BASE_URL}/orders`, JSON.stringify({
      customer_id: 1,
      product: 'Test Product',
      quantity: 0,
    }), { headers: { 'Content-Type': 'application/json' } });
    check(res, {
      'zero quantity returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Order with negative quantity', () => {
    const res = http.post(`${BASE_URL}/orders`, JSON.stringify({
      customer_id: 1,
      product: 'Test Product',
      quantity: -5,
    }), { headers: { 'Content-Type': 'application/json' } });
    check(res, {
      'negative quantity returns 400': (r) => r.status === 400,
    });
    errorRate.add(res.status !== 400);
  });

  group('Order not found', () => {
    const res = http.get(`${BASE_URL}/orders/999999`);
    check(res, {
      'missing order returns 404': (r) => r.status === 404,
    });
    errorRate.add(res.status !== 404);
  });

  group('Unknown route', () => {
    const res = http.get(`${BASE_URL}/unknown`);
    check(res, {
      'unknown route returns 404': (r) => r.status === 404,
    });
    errorRate.add(res.status !== 404);
  });

  group('Health check', () => {
    const res = http.get(`${BASE_URL}/healthz`);
    check(res, {
      'healthz returns 200': (r) => r.status === 200,
      'healthz body ok': (r) => JSON.parse(r.body).status === 'ok',
    });
    errorRate.add(res.status !== 200);
  });
}

export function handleSummary(data) {
  const out = {};

  const lines = ['\n=== Error Path Test Summary ==='];
  if (data.root_group && data.root_group.groups) {
    for (const [gName, g] of Object.entries(data.root_group.groups)) {
      lines.push(`  ${gName}:`);
      if (g.checks) {
        for (const [, c] of Object.entries(g.checks)) {
          const total = c.passes + c.fails;
          const status = c.fails === 0 ? 'PASS' : 'FAIL';
          lines.push(`    [${status}] ${c.name} (${c.passes}/${total})`);
        }
      }
    }
  }
  lines.push('================================\n');
  out['stdout'] = lines.join('\n');

  if (__ENV.SUMMARY_JSON) {
    out[__ENV.SUMMARY_JSON] = JSON.stringify(data, null, 2);
  }

  return out;
}
