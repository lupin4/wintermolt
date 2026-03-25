// Twitch adapter — uses tmi.js
import tmi from 'tmi.js';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const channels = (process.env.TWITCH_CHANNELS ?? '').split(',').filter(Boolean);
  const username = process.env.TWITCH_USERNAME ?? 'wintermolt';

  const client = new tmi.Client({
    options: { debug: false },
    identity: {
      username,
      password: `oauth:${process.env.TWITCH_ACCESS_TOKEN!}`,
    },
    channels,
  });

  client.on('message', (channel: string, tags: any, message: string, self: boolean) => {
    if (self) return;

    sendToAgent({
      type: 'message',
      platform: 'twitch',
      from: tags['user-id'] ?? tags.username ?? 'unknown',
      fromName: tags['display-name'] ?? tags.username ?? undefined,
      channel,
      text: message,
    });
  });

  return {
    platform: 'twitch',

    async connect() {
      await client.connect();
    },

    async disconnect() {
      await client.disconnect();
    },

    async sendReply(to: string, text: string) {
      // Twitch has 500 char limit per message
      const chunks = splitText(text, 500);
      for (const chunk of chunks) {
        await client.say(to, chunk);
      }
    },
  };
}

function splitText(text: string, maxLen: number): string[] {
  if (text.length <= maxLen) return [text];
  const chunks: string[] = [];
  let remaining = text;
  while (remaining.length > 0) {
    chunks.push(remaining.slice(0, maxLen));
    remaining = remaining.slice(maxLen);
  }
  return chunks;
}
