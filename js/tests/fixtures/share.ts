// LLP 1133.024 D4 (amended 2026-11-22): a share handler, as #1273's league app
// writes one. It posts what precedes the address in the shared text to that
// address with the kept session, and answers the server's line; a 401 opens
// the app, which refreshes the session.
const appId = 'test.share-js';
const grants = 'net.fetch local-network development\nsecret.keep session\n';
type Share = { title: string | null; text: string | null; url: string | null };
function answer(source: string, [share]: [Share], store: any) {
  if (source !== 'submitShared') throw new Error(`no source ${source}`);
  const text = share.text ?? '';
  if (text === 'throw') throw new Error('private refusal');
  if (text === 'write') { store.set('session', 'refreshed'); return { outcome: 'done', message: null }; }
  const at = text.indexOf('http://');
  if (at < 0) return { outcome: 'refused', message: 'That is not a puzzle result.' };
  return fetch(text.slice(at), { method: 'POST', headers: { authorization: `Bearer ${store.get('session')}` }, body: text.slice(0, at).trim() })
    .then(r => r.status === 401 ? { outcome: 'open', message: null } : r.text().then(line => ({ outcome: 'done', message: line })));
}
(globalThis as any).exact = { abi: 1, appId, grants, answer };
