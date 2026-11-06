const API = 'https://ww.sckang.cc';
const UIDS = new Set(['MYDESKPC_60cf84ad1ea2', 'MYTUFPC_4e8bb5ec68f3']);
const validGrant = (grant, now) => grant && /^pr_[A-Za-z0-9_-]{43}$/.test(grant.token)
  && Number.isFinite(grant.issuedAt) && Number.isFinite(grant.expiresAt)
  && grant.expiresAt > now && grant.issuedAt <= now + 30_000
  && grant.expiresAt - grant.issuedAt === 600_000 && grant.expiresAt <= now + 630_000;

export function createHandshake({ popup, nonce, now = Date.now }) {
  let state = 'waiting'; const deadline = now() + 120_000;
  return {
    cancel() { state = 'done'; },
    receive(event) {
      if (state === 'done' || now() >= deadline || event.origin !== API || event.source !== popup || !popup) return;
      const data = event.data;
      if (data?.type === 'ready' && state === 'waiting') {
        state = 'challenged'; return { type: 'challenge', nonce };
      }
      if (data?.type === 'grant' && state === 'challenged' && data.nonce === nonce && validGrant(data, now())) {
        state = 'done';
        return { type: 'accepted', grant: { token: data.token, issuedAt: data.issuedAt, expiresAt: data.expiresAt } };
      }
    },
  };
}

export function createSseParser(onEvent) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let line = '', event = '', data = [], bytes = 0, skipLf = false;
  function endLine() {
    if (!line) {
      if (data.length) onEvent({ event: event || 'message', data: data.join('\n') });
      event = ''; data = []; bytes = 0;
    } else if (!line.startsWith(':')) {
      const colon = line.indexOf(':'), key = colon < 0 ? line : line.slice(0, colon);
      const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
      if (key === 'event') event = value;
      if (key === 'data') data.push(value);
    }
    line = '';
  }
  return { feed(chunk) {
    for (const byte of chunk) {
      if (++bytes > 65536) throw new Error('SSE_FRAME_TOO_LARGE');
      for (const char of decoder.decode(new Uint8Array([byte]), { stream: true })) {
        if (skipLf && char === '\n') { skipLf = false; continue; }
        skipLf = false;
        if (char === '\r') { endLine(); skipLf = true; }
        else if (char === '\n') endLine();
        else line += char;
      }
    }
  } };
}

function safeSnapshot(value) {
  if (!Array.isArray(value) || value.length > 2) throw new Error('INVALID_SNAPSHOT');
  const found = new Set();
  return value.map(d => {
    if (!UIDS.has(d?.uid) || found.has(d.uid) || typeof d.online !== 'boolean'
      || (d.lastSeen !== null && !Number.isFinite(Date.parse(d.lastSeen)))) throw new Error('INVALID_SNAPSHOT');
    found.add(d.uid);
    const result = { uid: d.uid, online: d.online, lastSeen: d.lastSeen };
    for (const key of ['displayName', 'state', 'step', 'server', 'payloadVersion']) {
      if (typeof d[key] !== 'string' || d[key].length > 160) throw new Error('INVALID_SNAPSHOT');
      result[key] = d[key];
    }
    return result;
  });
}

export function createPilotSession({ fetcher = fetch, onDevices, onConnection, clock = Date.now,
  setTimer = setTimeout, clearTimer = clearTimeout }) {
  let generation = 0, grant, controller, expiry, retry, idle;
  function stop(label = 'stale') {
    generation++; grant = undefined; controller?.abort();
    clearTimer(expiry); clearTimer(retry); clearTimer(idle); onConnection(label);
  }
  async function stream(current, attempt = 0) {
    if (current !== generation || !grant) return;
    if (clock() >= grant.expiresAt) { stop('expired'); return; }
    const ownController = new AbortController(); controller = ownController;
    const armIdle = () => { clearTimer(idle); idle = setTimer(() => {
      if (current === generation) { onConnection('stale'); ownController.abort(); }
    }, 45_000); idle.unref?.(); };
    armIdle();
    try {
      const response = await fetcher(API + '/api/v1/pages-readonly/events', {
        method: 'GET', credentials: 'omit', mode: 'cors', redirect: 'error', cache: 'no-store',
        headers: { Authorization: 'Bearer ' + grant.token }, signal: ownController.signal,
      });
      if (current !== generation) { await response.body?.cancel(); return; }
      if (response.status === 401 || response.status === 403 || response.status === 404) { await response.body?.cancel(); stop('expired'); return; }
      if (!response.ok || !response.headers.get('content-type')?.startsWith('text/event-stream')) {
        await response.body?.cancel(); throw new Error('STREAM_UNAVAILABLE');
      }
      const parser = createSseParser(frame => {
        if (current !== generation || !grant || clock() >= grant.expiresAt || frame.event !== 'devices') return;
        onDevices(safeSnapshot(JSON.parse(frame.data).devices)); armIdle(); onConnection('live'); attempt = 0;
      });
      for await (const chunk of response.body) { if (current !== generation) break; parser.feed(chunk); }
    } catch { /* No error strings or credentials are logged. Last snapshot remains visible as stale. */ }
    finally {
      ownController.abort();
      if (current === generation) {
        clearTimer(idle); onConnection('stale');
        retry = setTimer(() => stream(current, attempt + 1), Math.min(15_000, 2000 * 2 ** Math.min(attempt, 3)));
      }
    }
  }
  return { stop, connect(value) {
    stop('connecting');
    if (!validGrant(value, clock())) { onConnection('expired'); return; }
    grant = { ...value };
    expiry = setTimer(() => stop('expired'), grant.expiresAt - clock());
    void stream(generation);
  } };
}

if (typeof document !== 'undefined') {
  const status = document.getElementById('connection'), cards = document.getElementById('devices');
  const labels = { live: '即時連線中', stale: '連線中斷：以下為最後取得的狀態', connecting: '正在連線…', expired: '授權已到期或撤銷，請重新連接' };
  const session = createPilotSession({ onConnection(value) { status.textContent = labels[value]; status.dataset.state = value; },
    onDevices(devices) {
      cards.replaceChildren(...devices.map(device => {
        const card = document.createElement('article'), name = document.createElement('h2'), info = document.createElement('p'), detail = document.createElement('p');
        name.textContent = device.displayName;
        info.textContent = `${device.online ? '在線' : '離線'} · ${device.state} · ${device.step || '—'}`;
        detail.textContent = `${device.server || '預設伺服器'} · v${device.payloadVersion} · 心跳 ${device.lastSeen ? new Date(device.lastSeen).toLocaleTimeString('zh-TW') : '未知'}`;
        card.append(name, info, detail); return card;
      }));
    },
  });
  let handshake, popup, handshakeTimer;
  const cancel = () => { handshake?.cancel(); clearTimeout(handshakeTimer); if (popup && !popup.closed) popup.close(); popup = undefined; };
  document.getElementById('connect').addEventListener('click', () => {
    cancel(); session.stop('connecting');
    const nonce = [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, '0')).join('');
    // Deliberately keep opener for the exact-origin + exact-window challenge; no credentials in the URL.
    popup = window.open(API + '/pages-readonly-authorize.html', '_blank', 'popup,width=480,height=560');
    if (!popup) { status.textContent = '請允許此頁開啟授權視窗後，再按一次連接。'; return; }
    handshake = createHandshake({ popup, nonce });
    handshakeTimer = setTimeout(() => { cancel(); status.textContent = '授權視窗逾時，請重新連接。'; }, 120_000);
  });
  window.addEventListener('message', event => {
    const result = handshake?.receive(event);
    if (result?.type === 'challenge') popup.postMessage(result, API);
    if (result?.type === 'accepted') { cancel(); session.connect(result.grant); }
  });
  document.getElementById('disconnect').addEventListener('click', () => { cancel(); session.stop(); status.textContent = '已停止讀取；授權最遲於 10 分鐘到期。'; });
  window.addEventListener('pagehide', () => { cancel(); session.stop(); });
}
