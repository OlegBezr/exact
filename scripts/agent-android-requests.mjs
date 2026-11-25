// What the reader carrier does with a driver's request beside relaying it to the app (`agent-android.mjs`'s `relay`).

import { basename, dirname } from 'node:path';

/** Each of a drag in's files (`tap <target> drop|dragenter <path…>`, LLP 1094.001 D6), this Mac's, to a folder of its
 * own under [base] on the device, where the app reads it: the request as the app is to get it, and each push as
 * `[local, remote]`. */
export function dropPushes(request, base) {
  const kind = ['drop', 'dragenter'].find((k) => Array.isArray(request?.[k]) && request[k].length);
  if (request?.op !== 'tap' || !kind) return { request, pushes: [] };
  const pushes = request[kind].map((path, i) => [path, `${base}/${dropPushes.next++}-${i}/${basename(path)}`]);
  return { request: { ...request, [kind]: pushes.map(([, remote]) => remote) }, pushes };
}
dropPushes.next = 0;

/** Puts [request]'s files on the device through [sh] (adb's words): the request naming them there, none when it
 * names no file, or an error naming the file that could not be put there. */
export function pushDrops(request, base, sh) {
  const { request: moved, pushes } = dropPushes(request, base);
  for (const [local, remote] of pushes) {
    const made = sh('shell', 'mkdir', '-p', `'${dirname(remote)}'`);
    const pushed = made.status === 0 ? sh('push', local, remote) : made;
    if (pushed.status !== 0) return { error: `the drop's file ${local} could not be put on the device: ${(pushed.stderr || pushed.stdout).trim()}` };
  }
  if (!pushes.length) return {};
  sh('shell', 'chmod', '-R', 'a+rX', base);
  return { request: moved };
}

/** The app's reply to [request], after the wait the app asks of a held contact. */
export async function readerReply(request, ask, wait = Bun.sleep) {
  const reply = await ask();
  if (request?.op === 'tap' && request.phase === 'hold') {
    // The host owns this decision, including while a capture borrows a seekable drive's clock.
    const { waitMs } = JSON.parse(reply);
    if (waitMs > 0) await wait(waitMs);
  }
  return reply;
}
