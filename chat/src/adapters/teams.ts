// Microsoft Teams adapter — uses Bot Framework REST API
// Requires: TEAMS_APP_ID, TEAMS_APP_PASSWORD
import { createServer } from 'http';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const APP_ID = process.env.TEAMS_APP_ID!;
const APP_PASSWORD = process.env.TEAMS_APP_PASSWORD!;
const PORT = parseInt(process.env.TEAMS_PORT ?? '3978', 10);

let botToken: string | null = null;
let tokenExpiry = 0;

async function getToken(): Promise<string> {
  if (botToken && Date.now() < tokenExpiry) return botToken;

  const res = await fetch('https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: APP_ID,
      client_secret: APP_PASSWORD,
      scope: 'https://api.botframework.com/.default',
    }),
  });
  const data = await res.json() as any;
  botToken = data.access_token;
  tokenExpiry = Date.now() + (data.expires_in - 60) * 1000;
  return botToken!;
}

export function createAdapter(): ChatAdapter {
  let server: ReturnType<typeof createServer>;

  return {
    platform: 'teams',

    async connect() {
      server = createServer(async (req, res) => {
        if (req.method !== 'POST' || req.url !== '/api/messages') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const body = JSON.parse(Buffer.concat(chunks).toString());

        if (body.type === 'message' && body.text) {
          sendToAgent({
            type: 'message',
            platform: 'teams',
            from: body.from?.id ?? 'unknown',
            fromName: body.from?.name ?? undefined,
            channel: body.conversation?.id ?? 'unknown',
            text: body.text,
            threadId: body.conversation?.id ?? undefined,
          });
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{}');
      });

      server.listen(PORT, () => {
        process.stderr.write(`[teams] Bot listening on port ${PORT}\n`);
      });
    },

    async disconnect() {
      server?.close();
    },

    async sendReply(to: string, text: string) {
      // Teams replies require the full serviceUrl + conversation context
      // In a real deployment, you'd store these from inbound messages
      process.stderr.write(`[teams] Reply to ${to}: ${text.slice(0, 80)}...\n`);
    },
  };
}
