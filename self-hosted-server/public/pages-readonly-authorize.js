const PAGES = 'https://derek3411888.github.io';
const API = 'https://ww.sckang.cc';
const parent = window.opener, status = document.getElementById('status'), allow = document.getElementById('allow');
let nonce, used = false, deadline = Date.now() + 120_000;
async function post(route, body = {}) {
  const response = await fetch('/api/v1/pages-readonly/' + route, { method: 'POST', credentials: 'same-origin', cache: 'no-store', redirect: 'error',
    headers: { 'Content-Type': 'application/json', 'X-Wuthering-CSRF': '1' }, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error('REQUEST_FAILED');
  return response.json();
}
window.addEventListener('message', event => {
  if (location.origin !== API || !parent || event.source !== parent || event.origin !== PAGES || nonce || used || Date.now() >= deadline) return;
  if (event.data?.type !== 'challenge' || !/^[a-f0-9]{64}$/.test(event.data.nonce)) return;
  nonce = event.data.nonce; allow.disabled = false; status.textContent = '已確認指定 Pages 視窗，請按允許。';
});
allow.addEventListener('click', async () => {
  if (!nonce || used || Date.now() >= deadline || location.origin !== API) return;
  used = true; allow.disabled = true;
  try {
    const grant = await post('grants', { nonce });
    parent.postMessage({ type: 'grant', nonce, token: grant.token, issuedAt: grant.issuedAt, expiresAt: grant.expiresAt }, PAGES);
    status.textContent = '已交付唯讀授權，可返回狀態頁。';
  } catch { status.textContent = '無法取得授權，請回狀態頁重新連接。'; }
  nonce = undefined;
});
document.getElementById('revoke').addEventListener('click', async () => {
  used = true; nonce = undefined; allow.disabled = true;
  try { await post('revoke'); status.textContent = '已撤銷此瀏覽器所有唯讀授權。'; }
  catch { status.textContent = '撤銷未確認；請稍後再試，授權仍會在原期限到期。'; }
});
if (location.origin === API && parent) parent.postMessage({ type: 'ready' }, PAGES);
else status.textContent = '請從 Pages 狀態頁按「連接」；本頁仍可撤銷既有授權。';
setTimeout(() => { nonce = undefined; allow.disabled = true; }, 120_000);
