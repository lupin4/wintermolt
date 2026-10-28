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
    // In a group, msg.from is the group and msg.author is the person who
    // wrote it. Using msg.from as the sender made a whole group one sender.
    const isGroup = String(msg.from).endsWith('@g.us');
    const me = client.info?.wid?._serialized;
    const repliesToMe = msg.hasQuotedMsg && (await msg.getQuotedMessage())?.fromMe === true;
    sendToAgent({
      type: 'message',
      platform: 'whatsapp',
      from: isGroup ? msg.author : msg.from,
      fromName: contact.pushname ?? contact.name ?? undefined,
      channel: msg.from,
      text: msg.body,
      chatType: isGroup ? 'group' : 'direct',
      mentioned: (!!me && (msg.mentionedIds ?? []).includes(me)) || repliesToMe,
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
