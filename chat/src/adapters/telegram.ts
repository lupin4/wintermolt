// Telegram adapter — uses telegraf
import { Telegraf } from 'telegraf';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const bot = new Telegraf(process.env.TELEGRAM_BOT_TOKEN!);

  bot.on('text', (ctx) => {
    const msg = ctx.message;
    sendToAgent({
      type: 'message',
      platform: 'telegram',
      from: String(msg.from.id),
      fromName: msg.from.username ?? msg.from.first_name,
      channel: String(msg.chat.id),
      text: msg.text,
      threadId: msg.message_thread_id ? String(msg.message_thread_id) : undefined,
      replyTo: msg.reply_to_message ? String(msg.reply_to_message.message_id) : undefined,
      chatType: msg.chat.type === 'private' ? 'direct' : 'group',
      mentioned: mentionsBot(msg, ctx.botInfo),
    });
  });

  return {
    platform: 'telegram',

    async connect() {
      bot.launch();
    },

    async disconnect() {
      bot.stop();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      const opts: any = {};
      if (threadId) opts.message_thread_id = Number(threadId);
      // Split long messages (Telegram 4096 char limit)
      const chunks = splitText(text, 4096);
      for (const chunk of chunks) {
        await bot.telegram.sendMessage(to, chunk, opts);
      }
    },

    async sendVoice(to: string, audioBase64: string) {
      const buf = Buffer.from(audioBase64, 'base64');
      await bot.telegram.sendVoice(to, { source: buf, filename: 'voice.ogg' });
    },
  };
}

/** An @username mention of the bot, a mention of its account, or a reply to
 *  one of its messages. */
function mentionsBot(msg: any, me: { id: number; username?: string }): boolean {
  if (msg.reply_to_message?.from?.id === me.id) return true;
  const handle = me.username ? '@' + me.username.toLowerCase() : null;
  for (const e of msg.entities ?? []) {
    if (e.type === 'text_mention' && e.user?.id === me.id) return true;
    if (e.type === 'mention' && handle &&
        msg.text.slice(e.offset, e.offset + e.length).toLowerCase() === handle) return true;
  }
  return false;
}

function splitText(text: string, maxLen: number): string[] {
  if (text.length <= maxLen) return [text];
  const chunks: string[] = [];
  let remaining = text;
  while (remaining.length > 0) {
    chunks.push(remaining.slice(0, maxLen));
    remaining = remaining.slice(maxLen);
  }
  return chunks;
}
