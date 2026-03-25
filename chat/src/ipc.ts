// Wintermolt Chat Sidecar — IPC Bridge
//
// Reads JSON lines from stdin (replies from Zig agent)
// Writes JSON lines to stdout (messages from chat platforms)

import { createInterface } from 'readline';
import type { InboundMessage, StatusEvent, OutboundMessage } from './types.js';

/** Send a message to the Zig agent via stdout */
export function sendToAgent(msg: InboundMessage | StatusEvent): void {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

/** Read replies from the Zig agent via stdin */
export function listenForReplies(
  handler: (msg: OutboundMessage) => void,
): void {
  const rl = createInterface({ input: process.stdin, terminal: false });

  rl.on('line', (line: string) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    try {
      const parsed = JSON.parse(trimmed) as OutboundMessage;
      handler(parsed);
    } catch {
      process.stderr.write(`[ipc] Invalid JSON from agent: ${trimmed}\n`);
    }
  });

  rl.on('close', () => {
    process.stderr.write('[ipc] Agent closed stdin, shutting down\n');
    process.exit(0);
  });
}
