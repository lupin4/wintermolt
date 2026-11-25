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

  // 'privmsg' only. irc-framework also emits 'message' for every PRIVMSG (and
  // for NOTICEs, which a bot must never answer), so listening to both handed
  // each line to the agent twice -- the second time as a DM from its sender.
  client.on('privmsg', (event: any) => {
    const me: string = client.user?.nick ?? nick;
    if (event.nick === me) return;
    const direct = event.target.toLowerCase() === me.toLowerCase();
    const text: string = event.message;
    const lower = text.toLowerCase();
    const myNick = me.toLowerCase();

    sendToAgent({
      type: 'message',
      platform: 'irc',
      from: event.nick,
      channel: direct ? event.nick : event.target, // a DM is answered to its sender
      text,
      chatType: direct ? 'direct' : 'group',
      // "nick: ..." / "nick, ..." addresses the bot; so does @nick anywhere.
      mentioned: lower.startsWith(myNick + ':') || lower.startsWith(myNick + ',') ||
        lower.includes('@' + myNick),
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
