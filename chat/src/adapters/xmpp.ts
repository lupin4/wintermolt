// XMPP/Jabber adapter — uses @xmpp/client
// Requires: XMPP_JID, XMPP_PASSWORD, optional XMPP_HOST
import { client, xml } from '@xmpp/client';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const jid = process.env.XMPP_JID!;
  const password = process.env.XMPP_PASSWORD!;
  const service = process.env.XMPP_HOST ?? `xmpps://${jid.split('@')[1]}:5223`;

  const xmppClient = client({
    service,
    username: jid.split('@')[0],
    password,
  });

  xmppClient.on('stanza', (stanza: any) => {
    if (!stanza.is('message') || stanza.attrs.type === 'error') return;
    const body = stanza.getChildText('body');
    if (!body) return;

    const from = stanza.attrs.from;
    const bareJid = from.split('/')[0];

    sendToAgent({
      type: 'message',
      platform: 'xmpp',
      from: bareJid,
      channel: bareJid,
      text: body,
      threadId: stanza.getChild('thread')?.text() ?? undefined,
    });
  });

  xmppClient.on('error', (err: Error) => {
    process.stderr.write(`[xmpp] Error: ${err.message}\n`);
  });

  return {
    platform: 'xmpp',

    async connect() {
      await xmppClient.start();
      // Send presence to appear online
      await xmppClient.send(xml('presence'));
    },

    async disconnect() {
      await xmppClient.stop();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      const msg = xml(
        'message',
        { type: 'chat', to },
        xml('body', {}, text),
        ...(threadId ? [xml('thread', {}, threadId)] : []),
      );
      await xmppClient.send(msg);
    },
  };
}
