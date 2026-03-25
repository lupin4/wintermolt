// Rocket.Chat adapter — uses REST + Realtime API
// Requires: ROCKETCHAT_URL, ROCKETCHAT_TOKEN, ROCKETCHAT_USER_ID
import WebSocket from 'ws';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const BASE_URL = process.env.ROCKETCHAT_URL!.replace(/\/$/, '');
const TOKEN = process.env.ROCKETCHAT_TOKEN!;
const USER_ID = process.env.ROCKETCHAT_USER_ID!;

export function createAdapter(): ChatAdapter {
  let ws: WebSocket | null = null;
  let msgId = 0;

  function sendWs(method: string, params: any[]): void {
    ws?.send(JSON.stringify({
      msg: 'method',
      method,
      id: String(++msgId),
      params,
    }));
  }

  return {
    platform: 'rocketchat',

    async connect() {
      const wsUrl = BASE_URL.replace(/^http/, 'ws') + '/websocket';
      ws = new WebSocket(wsUrl);

      ws.on('open', () => {
        ws!.send(JSON.stringify({ msg: 'connect', version: '1', support: ['1'] }));
      });

      ws.on('message', (data: any) => {
        try {
          const msg = JSON.parse(data.toString());

          if (msg.msg === 'connected') {
            // Login with token
            ws!.send(JSON.stringify({
              msg: 'method',
              method: 'login',
              id: String(++msgId),
              params: [{ resume: TOKEN }],
            }));
          }

          if (msg.msg === 'result' && msg.id === '1') {
            // Logged in, subscribe to messages
            ws!.send(JSON.stringify({
              msg: 'sub',
              id: String(++msgId),
              name: 'stream-room-messages',
              params: ['__my_messages__', false],
            }));
          }

          if (msg.msg === 'changed' && msg.collection === 'stream-room-messages') {
            for (const event of msg.fields?.args ?? []) {
              if (event.u?._id === USER_ID) continue;

              sendToAgent({
                type: 'message',
                platform: 'rocketchat',
                from: event.u?._id ?? 'unknown',
                fromName: event.u?.username ?? undefined,
                channel: event.rid,
                text: event.msg ?? '',
                threadId: event.tmid ?? undefined,
              });
            }
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
      await fetch(`${BASE_URL}/api/v1/chat.sendMessage`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Auth-Token': TOKEN,
          'X-User-Id': USER_ID,
        },
        body: JSON.stringify({
          message: {
            rid: to,
            msg: text,
            ...(threadId ? { tmid: threadId } : {}),
          },
        }),
      });
    },
  };
}
