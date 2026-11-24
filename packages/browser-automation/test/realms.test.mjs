import { expect, test } from 'bun:test';
import { suiteBrowser } from '../../../scripts/agent-launch.mjs';

async function inFrame(check) {
  const browser = await suiteBrowser();
  try {
    const page = await browser.newPage();
    const source = await Bun.file(new URL('../web/index.js', import.meta.url)).text();
    await page.route('http://wallet.test/**', route => {
      const path = new URL(route.request().url()).pathname;
      if (path === '/binding.js') return route.fulfill({ contentType: 'text/javascript', body: source });
      const body = path === '/' ? '<div id="exact-root"><iframe id="tab" src="/wallet"></iframe></div>' : '<title>Wallet</title>';
      return route.fulfill({ contentType: 'text/html', body });
    });
    await page.goto('http://wallet.test/');
    return await page.evaluate(check);
  } finally {
    await browser.close();
  }
}

test('ordinary frame calls work with a traced evaluator and a non-extensible document', async () => {
  expect(await inFrame(async () => {
    const api = (await import('/binding.js')).implementation();
    const win = document.querySelector('iframe').contentWindow;
    const evaluate = win.eval;
    win.eval = source => evaluate(source);
    const traced = await api.evaluate({ id: 'tab', expression: '21 * 2' });
    win.eval = evaluate;
    Object.preventExtensions(win.document);
    const sealed = await api.callFunction({ id: 'tab', functionDeclaration: 'x => x * 2', arguments: [21] });
    return [traced, sealed];
  })).toEqual([{ result: 42 }, { result: 42 }]);
}, 60_000);

test('a context reaches its frame and a realm target is unsupported on the web', async () => {
  expect(await inFrame(async () => {
    const api = (await import('/binding.js')).implementation();
    const context = await api.evaluate({ target: { context: 'tab' }, expression: 'document.title' });
    const refused = await api.callFunction({ target: { realm: 'old' }, functionDeclaration: '() => 42' });
    return [context, refused.error, refused.message.includes('realm')];
  })).toEqual([{ result: 'Wallet' }, 'NotSupportedError', true]);
}, 60_000);
