// IRC adapter — uses irc-framework
import IrcFramework from 'irc-framework';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const serverStr = process.env.IRC_SERVER!;
  const [host, portStr] = serverStr.split(':');
  const port = portStr ? parseInt(portStr, 10) : 6667;
  const nick = process.env.IRC_NICK ?? 'wintermolt';
  const channels = (process.env.IRC_CHANNELS ?? '').split(',').filter(Boolean);
  const useTls = port === 6697 || !!process.env.IRC_TLS;

  const client = new IrcFramework.Client();

  client.on('message', (event: any) => {
    if (event.nick === nick) return;

    sendToAgent({
      type: 'message',
      platform: 'irc',
      from: event.nick,
      channel: event.target,
      text: event.message,
    });
  });

  client.on('privmsg', (event: any) => {
    if (event.nick === nick) return;

    sendToAgent({
      type: 'message',
      platform: 'irc',
      from: event.nick,
      channel: event.nick, // DMs use sender as channel
      text: event.message,
    });
  });

  return {
    platform: 'irc',

    async connect() {
      return new Promise<void>((resolve) => {
        client.connect({
          host,
          port,
          nick,
          tls: useTls,
          password: process.env.IRC_PASSWORD,
        });

        client.on('registered', () => {
          for (const ch of channels) {
            client.join(ch.startsWith('#') ? ch : `#${ch}`);
          }
          resolve();
        });
      });
    },

    async disconnect() {
      client.quit('Wintermolt signing off');
    },

    async sendReply(to: string, text: string) {
      // Split by newlines — IRC is line-based
      for (const line of text.split('\n')) {
        if (line.trim()) client.say(to, line);
      }
    },
  };
}
