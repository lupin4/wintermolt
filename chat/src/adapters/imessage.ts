// iMessage adapter — macOS only, uses AppleScript via osascript
// Requires: macOS, IMESSAGE_APPLEID
// Polls the Messages SQLite database for new messages
import { execSync, exec } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';
import { sendToAgent } from '../ipc.js';
import type { ChatAdapter } from '../types.js';

const DB_PATH = join(process.env.HOME ?? '', 'Library/Messages/chat.db');
const POLL_INTERVAL = 3000; // ms

export function createAdapter(): ChatAdapter {
  let polling = false;
  let lastRowId = 0;

  async function poll(): Promise<void> {
    polling = true;

    // Get the latest ROWID to start from
    try {
      const initResult = execSync(
        `sqlite3 "${DB_PATH}" "SELECT MAX(ROWID) FROM message"`,
        { encoding: 'utf-8' },
      ).trim();
      lastRowId = parseInt(initResult, 10) || 0;
    } catch {
      process.stderr.write('[imessage] Could not read Messages database. Grant Full Disk Access.\n');
      return;
    }

    while (polling) {
      try {
        const query = `
          SELECT m.ROWID, m.text, m.is_from_me,
                 COALESCE(h.id, 'unknown') as sender,
                 COALESCE(c.chat_identifier, 'unknown') as chat_id
          FROM message m
          LEFT JOIN handle h ON m.handle_id = h.ROWID
          LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
          LEFT JOIN chat c ON cmj.chat_id = c.ROWID
          WHERE m.ROWID > ${lastRowId}
          ORDER BY m.ROWID ASC
          LIMIT 50
        `;

        const result = execSync(
          `sqlite3 -separator '|' "${DB_PATH}" "${query.replace(/\n/g, ' ')}"`,
          { encoding: 'utf-8' },
        ).trim();

        if (result) {
          for (const line of result.split('\n')) {
            const [rowId, text, isFromMe, sender, chatId] = line.split('|');
            lastRowId = parseInt(rowId, 10);

            if (isFromMe === '1' || !text) continue;

            sendToAgent({
              type: 'message',
              platform: 'imessage',
              from: sender,
              channel: chatId,
              text,
            });
          }
        }
      } catch {
        // Silently continue on read errors
      }

      await new Promise((r) => setTimeout(r, POLL_INTERVAL));
    }
  }

  return {
    platform: 'imessage',

    async connect() {
      if (process.platform !== 'darwin') {
        throw new Error('iMessage adapter requires macOS');
      }
      if (!existsSync(DB_PATH)) {
        throw new Error('Messages database not found. Grant Full Disk Access to terminal.');
      }
      poll().catch((err) => {
        process.stderr.write(`[imessage] Poll error: ${err}\n`);
      });
    },

    async disconnect() {
      polling = false;
    },

    async sendReply(to: string, text: string) {
      // Use AppleScript to send via Messages.app
      const escaped = text.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
      const script = `tell application "Messages"
        set targetBuddy to buddy "${to}" of service 1
        send "${escaped}" to targetBuddy
      end tell`;

      exec(`osascript -e '${script.replace(/'/g, "'\\''")}'`, (err) => {
        if (err) process.stderr.write(`[imessage] Send error: ${err.message}\n`);
      });
    },
  };
}
