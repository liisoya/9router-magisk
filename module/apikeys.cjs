/**
 * 通过本机 loopback 登录 dashboard 并管理 API Key（局域网访问 /v1 必须要 key）
 * 用法: node apikeys.cjs create [名称]  |  node apikeys.cjs list
 */
const fs = require('node:fs');
const path = require('node:path');

const DATA = '/data/adb/9router';
const ENV_FILE = path.join(DATA, 'env.sh');

const env = Object.fromEntries(
  fs.readFileSync(ENV_FILE, 'utf8').split('\n')
    .map((l) => /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(l.trim()))
    .filter(Boolean)
    .map((m) => [m[1], m[2].replace(/^["']|["']$/g, '')])
);
const PORT = env.APP_PORT || '20128';
const BASE = `http://127.0.0.1:${PORT}`;

const setEnvValue = (key, value) => {
  const lines = fs.readFileSync(ENV_FILE, 'utf8').split('\n');
  const next = lines.map((l) => (l.startsWith(`${key}=`) ? `${key}=${value}` : l));
  if (!lines.some((l) => l.startsWith(`${key}=`))) next.push(`${key}=${value}`);
  fs.writeFileSync(ENV_FILE, next.join('\n'));
};

async function login() {
  const res = await fetch(`${BASE}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: env.INITIAL_PASSWORD || '123456' }),
  });
  if (!res.ok) throw new Error(`登录失败: HTTP ${res.status} ${await res.text()}`);
  const cookie = res.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
  return cookie;
}

(async () => {
  const op = process.argv[2] || 'list';
  const cookie = await login();
  if (op === 'list') {
    const r = await fetch(`${BASE}/api/keys`, { headers: { Cookie: cookie } });
    const j = await r.json();
    console.log((j.keys || []).map((k) => `${k.name}\t${k.key}`).join('\n') || '(无)');
    return;
  }
  if (op === 'create') {
    const name = process.argv[3] || `android-${Date.now()}`;
    const r = await fetch(`${BASE}/api/keys`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Cookie: cookie },
      body: JSON.stringify({ name }),
    });
    const j = await r.json();
    if (!r.ok) throw new Error('创建失败: ' + JSON.stringify(j));
    setEnvValue('API_KEY', j.key);
    console.log(`已创建密钥: ${j.key}`);
    console.log(`局域网调用示例: curl -H "Authorization: Bearer ${j.key}" http://<手机IP>:${PORT}/v1/models`);
    return;
  }
  console.log('用法: apikeys.cjs create [名称] | list');
})().catch((e) => {
  console.error('错误:', e.message);
  process.exit(1);
});
