const UIDS = ['MYDESKPC_60cf84ad1ea2', 'MYTUFPC_4e8bb5ec68f3'];
export function companyView(raw) {
  if (!raw?.companyBridge) return raw;
  return { ...(raw.companySnapshot || { uid: raw.uid, state: 'OFFLINE', lastHeartbeat: 0 }),
    companyBridge: raw.companyBridge, companyRequest: raw.companyRequest, companyReceipt: raw.companyReceipt };
}
export function assertCompanyReady(uid, data, now = Date.now()) {
  const bridge = data?.companyBridge;
  if (!UIDS.includes(uid) || data.uid !== uid || bridge?.version !== 1 || bridge.enabled !== true || !bridge.epoch ||
      !Number.isFinite(bridge.heartbeatAt) || now - bridge.heartbeatAt > 150000 || bridge.heartbeatAt > now + 30000) {
    throw new Error('公司橋接尚未就緒或已過期；請等候下一次 60 秒同步。');
  }
  if (data.online !== true || !Number.isFinite(data.lastHeartbeat) || now - data.lastHeartbeat > 300000 || data.lastHeartbeat > now + 30000) {
    throw new Error('裝置目前離線或心跳過期，不能送出公司操作。');
  }
}
export function companyRequestUpdate(uid, raw, request, serverTimestamp, now = Date.now()) {
  const data = companyView(raw);
  assertCompanyReady(uid, data, now);
  const prior = raw.companyRequest, receipt = raw.companyReceipt;
  if (prior?.id && receipt?.id !== prior.id && prior.id !== request.id) throw new Error('上一筆公司請求仍等待橋接，請勿重複送出。');
  return { companyRequest: { version: 1, epoch: data.companyBridge.epoch, id: request.id, kind: request.kind,
    payload: request.payload, createdAt: serverTimestamp(), expectedNonce: Number(data.nonce), expectedRevision: Number(data.desiredSettingsRevision) } };
}
export function companyRequestStatus(data, kind = 'command') {
  const request = data?.companyRequest, receipt = data?.companyReceipt;
  if (!data?.companyBridge || request?.kind !== kind) return null;
  if (receipt?.id !== request.id) return { state: 'waiting', title: '等待公司橋接', detail: '每 60 秒處理新請求；尚未送達執行端。' };
  if (receipt.status === 'REJECTED') return { state: 'rejected', title: '公司請求未執行', detail: `${receipt.code || 'REJECTED'}：請重新整理確認目前狀態後再操作。` };
  if (receipt.status === 'ACCEPTED' && (kind === 'command' ? data.commandHistory?.some(c => c.commandNonce === receipt.nonce) : Number(data.desiredSettingsRevision) >= receipt.revision)) return null;
  return { state: 'waiting', title: '橋接已受理，等待裝置回覆', detail: '橋接收據不是裝置 ACK，不代表任務已執行。' };
}
