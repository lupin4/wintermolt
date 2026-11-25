// Matrix adapter — uses matrix-js-sdk
import sdk from 'matrix-js-sdk';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  const homeserver = process.env.MATRIX_HOMESERVER!;
  const accessToken = process.env.MATRIX_ACCESS_TOKEN!;
  const userId = process.env.MATRIX_USER_ID!;

  const client = sdk.createClient({
    baseUrl: homeserver,
    accessToken,
    userId,
  });

  /** A room the account lists as a DM (m.direct), or one with just the bot
   *  and one other member. */
  function isDirectRoom(room: any): boolean {
    if (!room) return false;
    const direct = (client.getAccountData('m.direct' as any)?.getContent() ?? {}) as Record<string, string[]>;
    if (Object.values(direct).some((rooms) => rooms.includes(room.roomId))) return true;
    return room.getJoinedMemberCount() === 2;
  }

  client.on(sdk.RoomEvent.Timeline as any, (event: any, room: any) => {
    if (event.getType() !== 'm.room.message') return;
    if (event.getSender() === userId) return;

    const content = event.getContent();
    if (content.msgtype !== 'm.text') return;

    sendToAgent({
      type: 'message',
      platform: 'matrix',
      from: event.getSender(),
      fromName: room?.getMember(event.getSender())?.name ?? undefined,
      channel: room?.roomId ?? 'unknown',
      text: content.body,
      threadId: content['m.relates_to']?.rel_type === 'm.thread'
        ? content['m.relates_to'].event_id
        : undefined,
      chatType: isDirectRoom(room) ? 'direct' : 'group',
      mentioned: (content['m.mentions']?.user_ids ?? []).includes(userId) ||
        String(content.body ?? '').includes(userId),
    });
  });

  return {
    platform: 'matrix',

    async connect() {
      await client.startClient({ initialSyncLimit: 0 });
    },

    async disconnect() {
      client.stopClient();
    },

    async sendReply(to: string, text: string, threadId?: string) {
      const content: any = {
        msgtype: 'm.text',
        body: text,
      };
      if (threadId) {
        content['m.relates_to'] = {
          rel_type: 'm.thread',
          event_id: threadId,
        };
      }
      await client.sendEvent(to, 'm.room.message', content);
    },
  };
}
