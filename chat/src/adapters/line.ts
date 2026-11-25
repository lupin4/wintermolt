// LINE adapter — uses @line/bot-sdk
import { createServer } from 'http';
import { createHmac, timingSafeEqual } from 'crypto';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const CHANNEL_SECRET = process.env.LINE_CHANNEL_SECRET!;
const CHANNEL_TOKEN = process.env.LINE_CHANNEL_TOKEN!;
const PORT = parseInt(process.env.LINE_PORT ?? '3980', 10);

/** X-Line-Signature is base64(HMAC-SHA256(channel secret, raw body)). */
function signatureValid(raw: Buffer, header: string | string[] | undefined): boolean {
  if (typeof header !== 'string') return false;
  const expected = createHmac('sha256', CHANNEL_SECRET).update(raw).digest();
  const given = Buffer.from(header, 'base64');
  return given.length === expected.length && timingSafeEqual(given, expected);
}

export function createAdapter(): ChatAdapter {
  let server: ReturnType<typeof createServer>;

  return {
    platform: 'line',

    async connect() {
      if (!CHANNEL_SECRET) {
        throw new Error('LINE_CHANNEL_SECRET is required: it verifies each webhook signature');
      }
      server = createServer(async (req, res) => {
        if (req.method !== 'POST' || req.url !== '/webhook') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const raw = Buffer.concat(chunks);

        // LINE signs every webhook with the channel secret. Without this check
        // anyone who can reach the port could post as any user.
        if (!signatureValid(raw, req.headers['x-line-signature'])) {
          res.writeHead(401);
          res.end();
          return;
        }
        const body = JSON.parse(raw.toString());

        for (const event of body.events ?? []) {
          if (event.type === 'message' && event.message.type === 'text' && event.source.userId) {
            const isGroup = event.source.type === 'group' || event.source.type === 'room';
            sendToAgent({
              type: 'message',
              platform: 'line',
              from: event.source.userId,
              channel: event.source.groupId ?? event.source.roomId ?? event.source.userId,
              text: event.message.text,
              replyTo: event.replyToken,
              chatType: isGroup ? 'group' : 'direct',
              mentioned: (event.message.mention?.mentionees ?? []).some((m: any) => m.isSelf === true),
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
