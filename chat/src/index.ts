// Wintermolt Chat Sidecar — Entry Point
//
// Discovers which platforms are configured (via env vars) and starts adapters.
// Bridges messages between chat platforms and the Zig agent via JSON lines IPC.

import { sendToAgent, listenForReplies } from './ipc.js';
import type { ChatAdapter, OutboundMessage } from './types.js';

// Platform adapters — lazy-loaded based on available credentials
const ADAPTER_REGISTRY: Record<string, {
  envCheck: () => boolean;
  load: () => Promise<ChatAdapter>;
}> = {
  discord: {
    envCheck: () => !!process.env.DISCORD_BOT_TOKEN,
    load: async () => (await import('./adapters/discord.js')).createAdapter(),
  },
  telegram: {
    envCheck: () => !!process.env.TELEGRAM_BOT_TOKEN,
    load: async () => (await import('./adapters/telegram.js')).createAdapter(),
  },
  whatsapp: {
    envCheck: () => !!process.env.WHATSAPP_PHONE_ID,
    load: async () => (await import('./adapters/whatsapp.js')).createAdapter(),
  },
  slack: {
    envCheck: () => !!process.env.SLACK_BOT_TOKEN,
    load: async () => (await import('./adapters/slack.js')).createAdapter(),
  },
  signal: {
    envCheck: () => !!process.env.SIGNAL_PHONE_NUMBER,
    load: async () => (await import('./adapters/signal.js')).createAdapter(),
  },
  irc: {
    envCheck: () => !!process.env.IRC_SERVER,
    load: async () => (await import('./adapters/irc.js')).createAdapter(),
  },
  matrix: {
    envCheck: () => !!process.env.MATRIX_HOMESERVER && !!process.env.MATRIX_ACCESS_TOKEN,
    load: async () => (await import('./adapters/matrix.js')).createAdapter(),
  },
  teams: {
    envCheck: () => !!process.env.TEAMS_APP_ID,
    load: async () => (await import('./adapters/teams.js')).createAdapter(),
  },
  googlechat: {
    envCheck: () => !!process.env.GOOGLE_CHAT_CREDENTIALS,
    load: async () => (await import('./adapters/googlechat.js')).createAdapter(),
  },
  line: {
    envCheck: () => !!process.env.LINE_CHANNEL_TOKEN,
    load: async () => (await import('./adapters/line.js')).createAdapter(),
  },
  feishu: {
    envCheck: () => !!process.env.FEISHU_APP_ID,
    load: async () => (await import('./adapters/feishu.js')).createAdapter(),
  },
  mattermost: {
    envCheck: () => !!process.env.MATTERMOST_URL && !!process.env.MATTERMOST_TOKEN,
    load: async () => (await import('./adapters/mattermost.js')).createAdapter(),
  },
  twitch: {
    envCheck: () => !!process.env.TWITCH_ACCESS_TOKEN,
    load: async () => (await import('./adapters/twitch.js')).createAdapter(),
  },
  nostr: {
    envCheck: () => !!process.env.NOSTR_PRIVATE_KEY,
    load: async () => (await import('./adapters/nostr.js')).createAdapter(),
  },
  xmpp: {
    envCheck: () => !!process.env.XMPP_JID && !!process.env.XMPP_PASSWORD,
    load: async () => (await import('./adapters/xmpp.js')).createAdapter(),
  },
  zulip: {
    envCheck: () => !!process.env.ZULIP_EMAIL && !!process.env.ZULIP_API_KEY,
    load: async () => (await import('./adapters/zulip.js')).createAdapter(),
  },
  rocketchat: {
    envCheck: () => !!process.env.ROCKETCHAT_URL && !!process.env.ROCKETCHAT_TOKEN,
    load: async () => (await import('./adapters/rocketchat.js')).createAdapter(),
  },
  imessage: {
    envCheck: () => process.platform === 'darwin' && !!process.env.IMESSAGE_APPLEID,
    load: async () => (await import('./adapters/imessage.js')).createAdapter(),
  },
};

const activeAdapters = new Map<string, ChatAdapter>();

async function main(): Promise<void> {
  process.stderr.write('[wintermolt-chat] Starting chat sidecar...\n');

  // Discover and start configured adapters
  const startPromises: Promise<void>[] = [];

  for (const [name, entry] of Object.entries(ADAPTER_REGISTRY)) {
    if (entry.envCheck()) {
      startPromises.push(
        (async () => {
          try {
            const adapter = await entry.load();
            await adapter.connect();
            activeAdapters.set(name, adapter);
            sendToAgent({
              type: 'status',
              platform: name,
              status: 'connected',
            });
            process.stderr.write(`[wintermolt-chat] ${name}: connected\n`);
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            process.stderr.write(`[wintermolt-chat] ${name}: failed to connect — ${msg}\n`);
            sendToAgent({
              type: 'status',
              platform: name,
              status: 'error',
              data: msg,
            });
          }
        })(),
      );
    }
  }

  await Promise.allSettled(startPromises);

  if (activeAdapters.size === 0) {
    process.stderr.write(
      '[wintermolt-chat] No platforms configured. Set env vars for at least one platform.\n' +
      '[wintermolt-chat] Supported: ' + Object.keys(ADAPTER_REGISTRY).join(', ') + '\n',
    );
    process.exit(1);
  }

  process.stderr.write(
    `[wintermolt-chat] Active platforms: ${[...activeAdapters.keys()].join(', ')}\n`,
  );

  // Listen for replies from the Zig agent and route to the right adapter
  listenForReplies((msg: OutboundMessage) => {
    const adapter = activeAdapters.get(msg.platform);
    if (!adapter) {
      process.stderr.write(`[wintermolt-chat] No adapter for platform: ${msg.platform}\n`);
      return;
    }

    if (msg.type === 'reply') {
      adapter.sendReply(msg.to, msg.text, msg.threadId).catch((err) => {
        process.stderr.write(`[wintermolt-chat] ${msg.platform} reply error: ${err}\n`);
      });
    } else if (msg.type === 'voice' && adapter.sendVoice) {
      adapter.sendVoice(msg.to, msg.audio).catch((err) => {
        process.stderr.write(`[wintermolt-chat] ${msg.platform} voice error: ${err}\n`);
      });
    }
  });

  // Graceful shutdown
  const shutdown = async () => {
    process.stderr.write('[wintermolt-chat] Shutting down...\n');
    for (const [name, adapter] of activeAdapters) {
      try {
        await adapter.disconnect();
      } catch {
        process.stderr.write(`[wintermolt-chat] ${name}: disconnect error\n`);
      }
    }
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  process.stderr.write(`[wintermolt-chat] Fatal: ${err}\n`);
  process.exit(1);
});
