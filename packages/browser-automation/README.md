# Script messages

Data code holding `browser.automation` can receive events from an injected script on macOS, iOS and Android. Pass a channel in a named sandbox.

```ts
import { addPreloadScript, type ScriptMessage } from '@exact/browser-automation';

export const grants = 'browser.automation';

export const tools = {
  'script.message'({ channel, data, source }: ScriptMessage) {
    if (channel === 'playback') console.log(source.realm, source.origin, data);
  },
};

export function watchPlayback() {
  return addPreloadScript({
    id: 'player',
    sandbox: 'float-track',
    arguments: [{ type: 'channel', value: { channel: 'playback' } }],
    functionDeclaration: `post => {
      document.addEventListener('pause', e => post({ event: 'pause', t: e.target.currentTime }), true);
    }`,
  });
}
```

| Operation | Arguments or delivery |
| --- | --- |
| `addPreloadScript` | Each `arguments` entry is a `ChannelValue`. The function receives the channels at document start. Each posts to the session that supplied it. Closing the session removes its channel preloads. On Android register the sandbox before navigating. |
| `callFunction` | A top-level `ChannelValue` becomes a post function at that position among ordinary JSON arguments. A realm target selects its existing sandbox. |
| `script.message` | The handler receives the channel name, JSON data and the posting world's realm, frame id (`context`) and host-supplied origin. A post survives navigation. Use `target: { realm }` for a wallet reply after approval. A reply to a replaced document answers `no such frame`. |
| Admission | The receiver needs `browser.automation`. Its handler runs with the runner’s `device` origin. A channel without a named sandbox, or on the web, answers `NotSupportedError`. |
| Bounds | More than 65,536 UTF-8 bytes of serialized JSON throws a catchable `QuotaExceededError`. One package session waits at least 50 ms after a handler finishes before starting the next one. Up to 32 posts wait. On overflow the oldest unsent posts are discarded and the runner journals one line for the backlog. |

Exact accepts `{ type: "channel", value: { channel } }` and delivers plain JSON by value. It adds the posting document’s origin to BiDi’s source. [ChannelValue](https://w3c.github.io/webdriver-bidi/#type-script-ChannelValue) · [script.message](https://w3c.github.io/webdriver-bidi/#event-script-message)
