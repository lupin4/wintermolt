// Slack adapter — uses @slack/bolt
import pkg from '@slack/bolt';
const { App } = pkg;
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const app = new App({
    token: process.env.SLACK_BOT_TOKEN!,
    appToken: process.env.SLACK_APP_TOKEN,
    socketMode: !!process.env.SLACK_APP_TOKEN,
  });

  app.message(async ({ message, say }) => {
    if (!('text' in message) || message.subtype) return;
    const m = message as any;

    sendToAgent({
      type: 'message',
      platform: 'slack',
      from: m.user,
      channel: m.channel,
      text: m.text ?? '',
      threadId: m.thread_ts ?? undefined,
      replyTo: m.thread_ts ?? undefined,
    });
  });

  return {
    platform: 'slack',

    async connect() {
      await app.start();
    },

    async disconnect() {
      await app.stop();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      await app.client.chat.postMessage({
        channel: to,
        text,
        thread_ts: threadId,
      });
    },
  };
}
