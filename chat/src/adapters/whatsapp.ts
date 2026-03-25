// WhatsApp adapter — uses whatsapp-web.js (unofficial, local Chrome)
import pkg from 'whatsapp-web.js';
const { Client: WAClient, LocalAuth } = pkg;
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const client = new WAClient({
    authStrategy: new LocalAuth(),
    puppeteer: { headless: true },
  });

  client.on('message', async (msg: any) => {
    if (msg.fromMe) return;

    const contact = await msg.getContact();
    sendToAgent({
      type: 'message',
      platform: 'whatsapp',
      from: msg.from,
      fromName: contact.pushname ?? contact.name ?? undefined,
      channel: msg.from,
      text: msg.body,
    });
  });

  client.on('qr', (qr: string) => {
    process.stderr.write(`[whatsapp] Scan QR code to authenticate:\n${qr}\n`);
    sendToAgent({
      type: 'status',
      platform: 'whatsapp',
      status: 'disconnected',
      data: 'Waiting for QR code scan',
    });
  });

  return {
    platform: 'whatsapp',

    async connect() {
      await client.initialize();
    },

    async disconnect() {
      await client.destroy();
    },

    async sendReply(to: string, text: string) {
      await client.sendMessage(to, text);
    },
  };
}
