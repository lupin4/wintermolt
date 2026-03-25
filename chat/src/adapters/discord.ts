// Discord adapter — uses discord.js
import { Client, GatewayIntentBits, type Message } from 'discord.js';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.DirectMessages,
      GatewayIntentBits.MessageContent,
    ],
  });

  client.on('messageCreate', (msg: Message) => {
    if (msg.author.bot) return;

    const roles = msg.member?.roles.cache
      .filter((r) => r.name !== '@everyone')
      .map((r) => r.name)
      .join(',');

    const attachments = msg.attachments.size > 0
      ? JSON.stringify([...msg.attachments.values()].map((a) => a.url))
      : undefined;

    sendToAgent({
      type: 'message',
      platform: 'discord',
      from: msg.author.id,
      fromName: msg.author.username,
      channel: msg.channel.id,
      text: msg.content,
      threadId: msg.channel.isThread() ? msg.channel.id : undefined,
      replyTo: msg.reference?.messageId ?? undefined,
      guild: msg.guild?.id ?? undefined,
      roles,
      attachments,
    });
  });

  return {
    platform: 'discord',

    async connect() {
      await client.login(process.env.DISCORD_BOT_TOKEN);
    },

    async disconnect() {
      client.destroy();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      const channel = await client.channels.fetch(threadId ?? to);
      if (channel?.isTextBased() && 'send' in channel) {
        // Split long messages (Discord 2000 char limit)
        const chunks = splitMessage(text, 2000);
        for (const chunk of chunks) {
          await (channel as any).send(chunk);
        }
      }
    },

    async sendVoice(to: string, audioBase64: string) {
      const channel = await client.channels.fetch(to);
      if (channel?.isTextBased() && 'send' in channel) {
        const buf = Buffer.from(audioBase64, 'base64');
        await (channel as any).send({
          files: [{ attachment: buf, name: 'voice.mp3' }],
        });
      }
    },
  };
}

function splitMessage(text: string, maxLen: number): string[] {
  if (text.length <= maxLen) return [text];
  const chunks: string[] = [];
  let remaining = text;
  while (remaining.length > 0) {
    chunks.push(remaining.slice(0, maxLen));
    remaining = remaining.slice(maxLen);
  }
  return chunks;
}
