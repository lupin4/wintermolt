// Feishu/Lark adapter — uses Feishu Open API
// Requires: FEISHU_APP_ID, FEISHU_APP_SECRET
import { createServer } from 'http';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const APP_ID = process.env.FEISHU_APP_ID!;
const APP_SECRET = process.env.FEISHU_APP_SECRET!;
const PORT = parseInt(process.env.FEISHU_PORT ?? '3981', 10);

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
      server = createServer(async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const body = JSON.parse(Buffer.concat(chunks).toString());

        // Feishu URL verification challenge
        if (body.challenge) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ challenge: body.challenge }));
          return;
        }

        const event = body.event;
        if (event?.message?.message_type === 'text') {
          const content = JSON.parse(event.message.content);
          sendToAgent({
            type: 'message',
            platform: 'feishu',
            from: event.sender?.sender_id?.user_id ?? 'unknown',
            channel: event.message.chat_id ?? 'unknown',
            text: content.text ?? '',
            threadId: event.message.root_id ?? undefined,
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
