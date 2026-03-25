// Google Chat adapter — uses Google Chat API via service account
// Requires: GOOGLE_CHAT_CREDENTIALS (path to service account JSON)
import { createServer } from 'http';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const PORT = parseInt(process.env.GOOGLE_CHAT_PORT ?? '3979', 10);

export function createAdapter(): ChatAdapter {
  let server: ReturnType<typeof createServer>;

  return {
    platform: 'googlechat',

    async connect() {
      // Google Chat sends events via webhook or Pub/Sub
      server = createServer(async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(404);
          res.end();
          return;
        }

        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const body = JSON.parse(Buffer.concat(chunks).toString());

        if (body.type === 'MESSAGE' && body.message?.text) {
          sendToAgent({
            type: 'message',
            platform: 'googlechat',
            from: body.message.sender?.name ?? 'unknown',
            fromName: body.message.sender?.displayName ?? undefined,
            channel: body.space?.name ?? 'unknown',
            text: body.message.text,
            threadId: body.message.thread?.name ?? undefined,
          });
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{}');
      });

      server.listen(PORT, () => {
        process.stderr.write(`[googlechat] Webhook listening on port ${PORT}\n`);
      });
    },

    async disconnect() {
      server?.close();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      // Requires Google Chat API with service account auth
      process.stderr.write(`[googlechat] Reply to ${to}: ${text.slice(0, 80)}...\n`);
    },
  };
}
