// Mattermost adapter — uses Mattermost WebSocket API
// Requires: MATTERMOST_URL, MATTERMOST_TOKEN
import WebSocket from 'ws';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const BASE_URL = process.env.MATTERMOST_URL!.replace(/\/$/, '');
const TOKEN = process.env.MATTERMOST_TOKEN!;

export function createAdapter(): ChatAdapter {
  let ws: WebSocket | null = null;
  let botUserId: string | null = null;

  return {
    platform: 'mattermost',

    async connect() {
      // Get bot user ID
      const meRes = await fetch(`${BASE_URL}/api/v4/users/me`, {
        headers: { Authorization: `Bearer ${TOKEN}` },
      });
      const me = await meRes.json() as any;
      botUserId = me.id;

      // Connect WebSocket
      const wsUrl = BASE_URL.replace(/^http/, 'ws') + '/api/v4/websocket';
      ws = new WebSocket(wsUrl);

      ws.on('open', () => {
        ws!.send(JSON.stringify({
          seq: 1,
          action: 'authentication_challenge',
          data: { token: TOKEN },
        }));
      });

      ws.on('message', (data: any) => {
        try {
          const event = JSON.parse(data.toString());
          if (event.event === 'posted') {
            const post = JSON.parse(event.data.post);
            if (post.user_id === botUserId) return;

            sendToAgent({
              type: 'message',
              platform: 'mattermost',
              from: post.user_id,
              fromName: event.data.sender_name ?? undefined,
              channel: post.channel_id,
              text: post.message,
              threadId: post.root_id || undefined,
            });
          }
        } catch {
          // skip
        }
      });
    },

    async disconnect() {
      ws?.close();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      await fetch(`${BASE_URL}/api/v4/posts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${TOKEN}`,
        },
        body: JSON.stringify({
          channel_id: to,
          message: text,
          root_id: threadId ?? '',
        }),
      });
    },
  };
}
