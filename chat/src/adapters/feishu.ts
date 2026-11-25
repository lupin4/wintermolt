// Feishu/Lark adapter — uses Feishu Open API
// Requires: FEISHU_APP_ID, FEISHU_APP_SECRET, FEISHU_VERIFICATION_TOKEN
import { createServer } from 'http';
import { timingSafeEqual } from 'crypto';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const APP_ID = process.env.FEISHU_APP_ID!;
const APP_SECRET = process.env.FEISHU_APP_SECRET!;
// Event Subscriptions → Verification Token in the Feishu developer console.
const VERIFICATION_TOKEN = process.env.FEISHU_VERIFICATION_TOKEN ?? '';
const PORT = parseInt(process.env.FEISHU_PORT ?? '3981', 10);

function tokenValid(token: unknown): boolean {
  if (typeof token !== 'string' || !VERIFICATION_TOKEN) return false;
  const a = Buffer.from(token);
  const b = Buffer.from(VERIFICATION_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** The bot's own open_id, to tell a mention of it from one of anyone else. */
let botOpenId: string | null = null;

let tenantToken: string | null = null;
let tokenExpiry = 0;

async function getToken(): Promise<string> {
  if (tenantToken && Date.now() < tokenExpiry) return tenantToken;

  const res = await fetch('https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ app_id: APP_ID, app_secret: APP_SECRET }),
  });
  const data = await res.json() as any;
  tenantToken = data.tenant_access_token;
  tokenExpiry = Date.now() + (data.expire - 60) * 1000;
  return tenantToken!;
}

export function createAdapter(): ChatAdapter {
  let server: ReturnType<typeof createServer>;

  return {
    platform: 'feishu',

    async connect() {
      if (!VERIFICATION_TOKEN) {
        throw new Error('FEISHU_VERIFICATION_TOKEN is required: it authenticates each event');
      }
      const info = await fetch('https://open.feishu.cn/open-apis/bot/v3/info', {
        headers: { Authorization: `Bearer ${await getToken()}` },
      }).then((r) => r.json() as any).catch(() => null);
      botOpenId = info?.bot?.open_id ?? null;
      if (!botOpenId) process.stderr.write('[feishu] Could not read the bot open_id; group mentions will not register\n');

      server = createServer(async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        let body: any;
        try {
          body = JSON.parse(Buffer.concat(chunks).toString());
        } catch {
          res.writeHead(400);
          res.end();
          return;
        }

        // Every Feishu event, the URL challenge included, carries the app's
        // verification token (v2 in header.token, v1 at the top). Without
        // this check anyone who can reach the port could post as any user.
        if (!tokenValid(body.header?.token ?? body.token)) {
          res.writeHead(401);
          res.end();
          return;
        }

        // Feishu URL verification challenge
        if (body.challenge) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ challenge: body.challenge }));
          return;
        }

        const event = body.event;
        const sender = event?.sender?.sender_id?.user_id ?? event?.sender?.sender_id?.open_id;
        if (event?.message?.message_type === 'text' && sender && event.message.chat_id) {
          const content = JSON.parse(event.message.content);
          sendToAgent({
            type: 'message',
            platform: 'feishu',
            from: sender,
            channel: event.message.chat_id,
            text: content.text ?? '',
            threadId: event.message.root_id ?? undefined,
            chatType: event.message.chat_type === 'p2p' ? 'direct' : 'group',
            mentioned: !!botOpenId && (event.message.mentions ?? []).some((m: any) =>
              m.id?.open_id === botOpenId),
          });
        }

        res.writeHead(200);
        res.end('{}');
      });

      server.listen(PORT, () => {
        process.stderr.write(`[feishu] Webhook listening on port ${PORT}\n`);
      });
    },

    async disconnect() {
      server?.close();
    },

    async sendReply(to: string, text: string) {
      const token = await getToken();
      await fetch('https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          receive_id: to,
          msg_type: 'text',
          content: JSON.stringify({ text }),
        }),
      });
    },
  };
}
