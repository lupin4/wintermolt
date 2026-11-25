// iMessage adapter — macOS only, uses AppleScript via osascript
// Requires: macOS, IMESSAGE_APPLEID
// Polls the Messages SQLite database for new messages
import { execSync, execFile } from 'child_process';
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
        // -json, not a '|' separator: text came before the sender column, so
        // a message containing '|' could shift the columns and name any
        // sender it liked -- the allowlisted one included.
        const query = `
          SELECT m.ROWID AS rowid, m.text AS text, m.is_from_me AS from_me,
                 h.id AS sender, c.chat_identifier AS chat_id,
                 c.guid AS chat_guid, c.style AS style
          FROM message m
          LEFT JOIN handle h ON m.handle_id = h.ROWID
          LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
          LEFT JOIN chat c ON cmj.chat_id = c.ROWID
          WHERE m.ROWID > ${lastRowId}
          ORDER BY m.ROWID ASC
          LIMIT 50
        `;

        const result = execSync(
          `sqlite3 -json "${DB_PATH}" "${query.replace(/\n/g, ' ')}"`,
          { encoding: 'utf-8' },
        ).trim();

        if (result) {
          for (const row of JSON.parse(result) as any[]) {
            lastRowId = row.rowid;

            if (row.from_me === 1 || !row.text || !row.sender || !row.chat_id) continue;

            // chat.style 43 is a group chat, 45 a one-to-one. A group is
            // answered by its chat GUID; a person by their handle.
            const isGroup = row.style === 43;
            sendToAgent({
              type: 'message',
              platform: 'imessage',
              from: row.sender,
              channel: isGroup ? row.chat_guid : row.chat_id,
              text: row.text,
              chatType: isGroup ? 'group' : 'direct',
              // Messages has no mention a script can read, so groups only
              // reach the agent with WINTERMOLT_CHAT_REQUIRE_MENTION=0.
              mentioned: false,
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
      // A group chat GUID ("iMessage;+;chat…") names a chat, not a buddy.
      const script = to.includes(';+;')
        ? `tell application "Messages"
        send "${escaped}" to chat id "${to}"
      end tell`
        : `tell application "Messages"
        set targetBuddy to buddy "${to}" of service 1
        send "${escaped}" to targetBuddy
      end tell`;

      // No shell: the reply is model output, and a sender can steer it.
      execFile('osascript', ['-e', script], (err) => {
        if (err) process.stderr.write(`[imessage] Send error: ${err.message}\n`);
      });
    },
  };
}
