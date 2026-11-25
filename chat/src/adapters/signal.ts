// Signal adapter — uses signal-cli via JSON-RPC over stdin/stdout
import { spawn, type ChildProcess } from 'child_process';
import { createInterface } from 'readline';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

export function createAdapter(): ChatAdapter {
  let proc: ChildProcess | null = null;
  const phone = process.env.SIGNAL_PHONE_NUMBER!;

  return {
    platform: 'signal',

    async connect() {
      // signal-cli must be installed and registered with the phone number
      proc = spawn('signal-cli', ['-a', phone, 'jsonRpc'], {
        stdio: ['pipe', 'pipe', 'inherit'],
      });

      const rl = createInterface({ input: proc.stdout!, terminal: false });

      rl.on('line', (line: string) => {
        try {
          const data = JSON.parse(line);
          if (data.method === 'receive') {
            const envelope = data.params?.envelope;
            const dm = envelope?.dataMessage;
            if (!dm?.message || !envelope.source) return;

            // A group message is answered in the group: channel "group:<id>",
            // which sendReply sends with groupId rather than to the sender.
            const groupId: string | undefined = dm.groupInfo?.groupId;
            const quote = dm.quote;
            sendToAgent({
              type: 'message',
              platform: 'signal',
              from: envelope.source,
              fromName: envelope.sourceName ?? undefined,
              channel: groupId ? `group:${groupId}` : envelope.source,
              text: dm.message,
              guild: groupId,
              chatType: groupId ? 'group' : 'direct',
              mentioned: (dm.mentions ?? []).some((m: any) => m.number === phone) ||
                (quote?.authorNumber ?? quote?.author) === phone,
            });
          }
        } catch {
          // skip non-JSON lines
        }
      });

      proc.on('exit', (code) => {
        process.stderr.write(`[signal] signal-cli exited with code ${code}\n`);
      });
    },

    async disconnect() {
      proc?.kill();
    },

    async sendReply(to: string, text: string) {
      if (!proc?.stdin) return;
      const req = {
        jsonrpc: '2.0',
        method: 'send',
        params: to.startsWith('group:')
          ? { groupId: to.slice('group:'.length), message: text }
          : { recipient: [to], message: text },
      };
      proc.stdin.write(JSON.stringify(req) + '\n');
    },
  };
}
