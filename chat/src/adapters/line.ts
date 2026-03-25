// LINE adapter — uses @line/bot-sdk
import { createServer } from 'http';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const CHANNEL_SECRET = process.env.LINE_CHANNEL_SECRET!;
const CHANNEL_TOKEN = process.env.LINE_CHANNEL_TOKEN!;
const PORT = parseInt(process.env.LINE_PORT ?? '3980', 10);

export function createAdapter(): ChatAdapter {
  let server: ReturnType<typeof createServer>;

  return {
    platform: 'line',

    async connect() {
      server = createServer(async (req, res) => {
        if (req.method !== 'POST' || req.url !== '/webhook') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const body = JSON.parse(Buffer.concat(chunks).toString());

        for (const event of body.events ?? []) {
          if (event.type === 'message' && event.message.type === 'text') {
            sendToAgent({
              type: 'message',
              platform: 'line',
              from: event.source.userId ?? 'unknown',
              channel: event.source.groupId ?? event.source.roomId ?? event.source.userId ?? 'dm',
              text: event.message.text,
              replyTo: event.replyToken,
            });
          }
        }

        res.writeHead(200);
        res.end('{}');
      });

      server.listen(PORT, () => {
        process.stderr.write(`[line] Webhook listening on port ${PORT}\n`);
      });
    },

    async disconnect() {
      server?.close();
    },

    async sendReply(to: string, text: string) {
      // Use LINE Messaging API push message
      await fetch('https://api.line.me/v2/bot/message/push', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${CHANNEL_TOKEN}`,
        },
        body: JSON.stringify({
          to,
          messages: [{ type: 'text', text }],
        }),
      });
    },
  };
}
