import type { Answer, Result, Sources } from './app.contract.d.ts';

export const grants = 'net.fetch https://www.apple.com\nsecret.keep session';

const sources: Sources = {
  greeting: ([name]): Result<'greeting'> => ({ text: `Hello from ${name}.` }),
  // The share handler (share_target.handle): one fetch, then the line under the checkmark.
  submitShared: async ([share]) => {
    if (share.text === 'refuse') return { outcome: 'refused', message: 'Refused by the handler.' };
    if (share.text === 'open') return { outcome: 'open', message: null };
    const response = await fetch('https://www.apple.com/library/test/success.html');
    return { outcome: 'done', message: `Fetched ${response.status}` };
  },
};
export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
