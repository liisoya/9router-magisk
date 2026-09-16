#!/system/bin/sh
/**
 * 9Router 控制面板（安卓模块版）
 * 只做“白名单操作”：把请求写进 control-request 文件，由 supervisor.sh 执行。
 * 本进程不会拼接任何 shell 命令。
 */
// eslint-disable-next-line
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const MODDIR = process.env.MODDIR || __dirname;
const DATA = process.env.DATA_DIR_HOME || '/data/adb/9router';
const ENV_FILE = path.join(DATA, 'env.sh');
const REQ_FILE = path.join(DATA, 'control-request');

const readEnv = () => {
  const out = {};
  try {
    for (const line of fs.readFileSync(ENV_FILE, 'utf8').split('\n')) {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
      if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  } catch {}
  return out;
};

const pidInfo = (file) => {
  const pid = Number(fs.readFileSync(file, 'utf8').trim() || '0') || 0;
  if (!pid) return null;
  try {
    const rss = /VmRSS:\s+(\d+)/.exec(fs.readFileSync(`/proc/${pid}/status`, 'utf8'));
    return { pid, rssMB: rss ? Math.round(Number(rss[1]) / 1024) : 0 };
  } catch {
    return null;
  }
};

const ips = () =>
  Object.values(os.networkInterfaces())
    .flat()
    .filter((n) => n && n.family === 'IPv4' && !n.internal)
    .map((n) => n.address);

const currentVersion = () => {
  try { return fs.readFileSync(path.join(DATA, 'current-version'), 'utf8').trim(); } catch { return '?'; }
};

const OPS = ['start', 'stop', 'restart', 'lan-on', 'lan-off', 'panel-on', 'panel-off'];

const status = () => {
  const env = readEnv();
  const core = pidInfo(path.join(DATA, '9router.pid'));
  const panel = pidInfo(path.join(DATA, 'panel.pid'));
  return {
    version: currentVersion(),
    running: !!core,
    pid: core ? core.pid : null,
    rssMB: core ? core.rssMB : 0,
    panelRunning: !!panel,
    panelRssMB: panel ? panel.rssMB : 0,
    appPort: env.APP_PORT || '20128',
    uiPort: env.UI_PORT || '20129',
    bind: env.BIND_HOST || '0.0.0.0',
    password: env.INITIAL_PASSWORD || '123456',
    lan: (env.BIND_HOST || '0.0.0.0') === '0.0.0.0',
    ips: ips(),
  };
};

const page = (s) => `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>9Router 控制面板</title>
<style>
:root{color-scheme:dark}
body{margin:0;background:#0b0f14;color:#e6edf3;font:15px/1.6 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:640px;margin:0 auto;padding:18px}
h1{font-size:19px;margin:6px 0 14px}
.card{background:#131a23;border:1px solid #243040;border-radius:12px;padding:14px 16px;margin-bottom:12px}
.row{display:flex;justify-content:space-between;gap:12px;padding:3px 0}
.row span:last-child{color:#9fb2c8;font-variant-numeric:tabular-nums}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;background:${s.running ? '#3fb950' : '#f85149'}}
a.btn,button.btn{display:inline-block;background:#1f6feb;border:0;color:#fff;padding:9px 13px;border-radius:9px;
 text-decoration:none;font-size:14px;margin:5px 6px 0 0;cursor:pointer}
a.btn.g,button.btn.g{background:#21262d;border:1px solid #30363d}
code{background:#0d1117;padding:2px 6px;border-radius:6px;font-size:13px}
small{color:#8b98a5}
</style></head><body><div class="wrap">
<h1><span class="dot"></span>9Router 控制面板</h1>
<div class="card">
 <div class="row"><span>服务状态</span><span>${s.running ? '运行中' : '已停止'} (PID ${s.pid || '-'})</span></div>
 <div class="row"><span>内存占用</span><span>${s.rssMB} MB</span></div>
 <div class="row"><span>面板进程</span><span>${s.panelRunning ? s.panelRssMB + ' MB' : '未运行'}</span></div>
 <div class="row"><span>合计内存</span><span>${s.rssMB + (s.panelRunning ? s.panelRssMB : 0)} MB</span></div>
 <div class="row"><span>应用版本</span><span>${s.version}</span></div>
</div>
<div class="card">
 <div class="row"><span>Dashboard 密码</span><span><code>${s.password}</code></span></div>
 <div class="row"><span>监听</span><span>${s.bind}:${s.appPort}</span></div>
 <div class="row"><span>本机地址</span><span>${s.ips.length ? s.ips.join(' · ') : '未连接网络'}</span></div>
 <div class="row"><span>Dashboard</span><span>${s.ips.length ? `<a style="color:#58a6ff" href="http://${s.ips[0]}:${s.appPort}/dashboard">http://${s.ips[0]}:${s.appPort}/dashboard</a>` : '-'}</span></div>
 <div class="row"><span>API 端点</span><span><code>http://${s.ips[0] || '127.0.0.1'}:${s.appPort}/v1</code></span></div>
</div>
<div class="card">
 <h3 style="margin:0 0 8px;font-size:15px">操作</h3>
 <button class="btn" onclick="op('${s.running ? 'stop' : 'start'}')">${s.running ? '停止服务' : '启动服务'}</button>
 <button class="btn g" onclick="op('restart')">重启服务</button>
 <button class="btn g" onclick="op('${s.lan ? 'lan-off' : 'lan-on'}')">${s.lan ? '切回仅本机' : '开放局域网'}</button>
 <button class="btn g" onclick="if(confirm('关闭后本页面立即失效（约 5 秒内），需要时在手机终端执行 9router ui on 重新开启。继续？'))op('panel-off')">关闭控制面板（省内存）</button>
 <small><br>操作由守护进程执行，约 5 秒内生效。面板本身约占 30MB 内存，不用时可以关掉。</small>
</div>
</div><script>
function op(name){
 fetch('/api/op/'+name).then(()=>setTimeout(()=>location.reload(),1200));
}
</script></body></html>`;

const server = http.createServer((req, res) => {
  const send = (code, body, type = 'text/html; charset=utf-8') => {
    res.writeHead(code, { 'Content-Type': type });
    res.end(body);
  };
  const url = req.url.split('?')[0];
  if (url === '/' || url === '/index.html') return send(200, page(status()));
  if (url === '/api/status') return send(200, JSON.stringify(status()), 'application/json');
  if (url.startsWith('/api/op/')) {
    const op = url.replace('/api/op/', '');
    if (!OPS.includes(op)) return send(400, JSON.stringify({ ok: false, error: 'unsupported op' }), 'application/json');
    fs.mkdirSync(DATA, { recursive: true });
    fs.writeFileSync(REQ_FILE, op);
    return send(200, JSON.stringify({ ok: true, op }), 'application/json');
  }
  send(404, 'not found');
});

const env = readEnv();
server.listen(Number(env.UI_PORT || 20129), env.BIND_HOST || '0.0.0.0', () => {
  console.log(`[control-center] listening on ${env.BIND_HOST || '0.0.0.0'}:${env.UI_PORT || 20129} (moddir=${MODDIR})`);
});
