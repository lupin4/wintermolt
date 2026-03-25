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
            if (!envelope?.dataMessage?.message) return;

            sendToAgent({
              type: 'message',
              platform: 'signal',
              from: envelope.source ?? 'unknown',
              fromName: envelope.sourceName ?? undefined,
              channel: envelope.source ?? 'dm',
              text: envelope.dataMessage.message,
              guild: envelope.dataMessage.groupInfo?.groupId ?? undefined,
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
        params: { recipient: [to], message: text },
      };
      proc.stdin.write(JSON.stringify(req) + '\n');
    },
  };
}
