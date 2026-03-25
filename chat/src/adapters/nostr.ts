// Nostr adapter — uses nostr-tools
import { getPublicKey, nip19, finalizeEvent, type Event } from 'nostr-tools';
import { Relay } from 'nostr-tools/relay';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const privateKeyHex = process.env.NOSTR_PRIVATE_KEY!;
  const privateKey = Uint8Array.from(Buffer.from(privateKeyHex, 'hex'));
  const pubkey = getPublicKey(privateKey);
  const relayUrls = (process.env.NOSTR_RELAYS ?? 'wss://relay.damus.io').split(',').filter(Boolean);
  const relays: Relay[] = [];

  return {
    platform: 'nostr',

    async connect() {
      for (const url of relayUrls) {
        try {
          const relay = await Relay.connect(url);

          relay.subscribe([
            { kinds: [4], '#p': [pubkey] }, // DMs to us
            { kinds: [1], '#p': [pubkey] }, // Mentions
          ], {
            onevent(event: Event) {
              if (event.pubkey === pubkey) return;

              sendToAgent({
                type: 'message',
                platform: 'nostr',
                from: nip19.npubEncode(event.pubkey),
                channel: event.pubkey,
                text: event.content,
              });
            },
          });

          relays.push(relay);
          process.stderr.write(`[nostr] Connected to ${url}\n`);
        } catch (err) {
          process.stderr.write(`[nostr] Failed to connect to ${url}: ${err}\n`);
        }
      }
    },

    async disconnect() {
      for (const relay of relays) {
        relay.close();
      }
    },

    async sendReply(to: string, text: string) {
      // Decode npub to hex if needed
      let recipientHex = to;
      if (to.startsWith('npub')) {
        const decoded = nip19.decode(to);
        recipientHex = decoded.data as string;
      }

      const event = finalizeEvent({
        kind: 4, // Encrypted DM
        created_at: Math.floor(Date.now() / 1000),
        tags: [['p', recipientHex]],
        content: text,
      }, privateKey);

      for (const relay of relays) {
        await relay.publish(event);
      }
    },
  };
}
