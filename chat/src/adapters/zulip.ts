// Zulip adapter — uses Zulip REST API with long-polling
// Requires: ZULIP_EMAIL, ZULIP_API_KEY, ZULIP_SITE
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const EMAIL = process.env.ZULIP_EMAIL!;
const API_KEY = process.env.ZULIP_API_KEY!;
const SITE = process.env.ZULIP_SITE!.replace(/\/$/, '');
const AUTH = `Basic ${Buffer.from(`${EMAIL}:${API_KEY}`).toString('base64')}`;

export function createAdapter(): ChatAdapter {
  let polling = false;
  let queueId: string | null = null;
  let lastEventId = -1;

  async function api(path: string, opts?: RequestInit): Promise<any> {
    const res = await fetch(`${SITE}/api/v1${path}`, {
      ...opts,
      headers: { Authorization: AUTH, ...opts?.headers },
    });
    return res.json();
  }

  async function poll(): Promise<void> {
    polling = true;

    // Register event queue
    const reg = await api('/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'event_types=["message"]',
    });
    queueId = reg.queue_id;
    lastEventId = reg.last_event_id;

    while (polling) {
      try {
        const data = await api(
          `/events?queue_id=${queueId}&last_event_id=${lastEventId}&dont_block=false`,
        );

        for (const event of data.events ?? []) {
          lastEventId = event.id;
          if (event.type !== 'message') continue;
          const msg = event.message;
          // Its own replies arrive as events too; answering them loops.
          if (msg.sender_email === EMAIL) continue;
          // A private message to just the bot has two recipients: it and the sender.
          const direct = msg.type === 'private' &&
            Array.isArray(msg.display_recipient) && msg.display_recipient.length <= 2;

          sendToAgent({
            type: 'message',
            platform: 'zulip',
            from: String(msg.sender_id),
            fromName: msg.sender_full_name,
            channel: msg.type === 'stream'
              ? `${msg.stream_id}:${msg.subject}`
              : String(msg.sender_id),
            text: msg.content,
            threadId: msg.subject ?? undefined,
            // The stream, so one WINTERMOLT_CHAT_GROUPS entry admits all its topics.
            guild: msg.type === 'stream' ? String(msg.stream_id) : undefined,
            chatType: direct ? 'direct' : 'group',
            mentioned: (event.flags ?? []).includes('mentioned'),
          });
        }
      } catch (err) {
        if (polling) {
          process.stderr.write(`[zulip] Poll error: ${err}\n`);
          await new Promise((r) => setTimeout(r, 5000));
        }
      }
    }
  }

  return {
    platform: 'zulip',

    async connect() {
      poll().catch((err) => {
        process.stderr.write(`[zulip] Fatal poll error: ${err}\n`);
      });
    },

    async disconnect() {
      polling = false;
      if (queueId) {
        await api(`/events?queue_id=${queueId}`, { method: 'DELETE' }).catch(() => {});
      }
    },

    async sendReply(to: string, text: string, threadId?: string) {
      const [streamId, subject] = to.includes(':') ? to.split(':') : [to, threadId ?? 'wintermolt'];
      const isStream = to.includes(':');

      const params = new URLSearchParams({
        type: isStream ? 'stream' : 'direct',
        content: text,
        ...(isStream
          ? { to: streamId, topic: subject }
          : { to: JSON.stringify([parseInt(to)]) }),
      });

      await api('/messages', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: params.toString(),
      });
    },
  };
}
