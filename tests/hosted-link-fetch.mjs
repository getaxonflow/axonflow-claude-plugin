// Hermetic Portal device-link fixture for the local install smoke.
import { appendFileSync } from 'node:fs';

globalThis.fetch = async (url, options) => {
  const parsed = new URL(url);
  if (parsed.origin !== 'https://portal.try.getaxonflow.com' || options.method !== 'POST') {
    throw new Error('unexpected link request');
  }
  const body = JSON.parse(options.body);
  if (parsed.pathname.endsWith('/device/start')) {
    if (!/^[0-9a-f]{64}$/.test(body.secret) || body.client_kind !== 'api') {
      throw new Error('invalid device start request');
    }
    appendFileSync(process.env.AXONFLOW_LINK_FETCH_LOG, 'start\n');
    return new Response(JSON.stringify({ device_code: 'a'.repeat(64), user_code: 'ABCDEFGHJK', expires_in: 900 }), { status: 201 });
  }
  if (parsed.pathname.endsWith('/device/poll')) {
    if (body.device_code !== 'a'.repeat(64)) throw new Error('invalid device poll request');
    appendFileSync(process.env.AXONFLOW_LINK_FETCH_LOG, 'poll\n');
    return new Response(JSON.stringify({ status: 'approved', tenant_id: 'cs_12345678-1234-1234-1234-123456789abc', expires_at: '2099-01-01T00:00:00Z' }), { status: 200 });
  }
  throw new Error('unexpected link path');
};
