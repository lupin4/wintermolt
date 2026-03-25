// Wintermolt Chat Sidecar — Types & Interfaces
//
// JSON lines IPC protocol between Zig agent and TypeScript chat sidecar.

/** Inbound message from a chat platform → Zig agent */
export interface InboundMessage {
  type: 'message';
  platform: string;
  from: string;
  fromName?: string;
  channel: string;
  text: string;
  threadId?: string;
  replyTo?: string;
  guild?: string;
  roles?: string;       // Comma-separated role names
  attachments?: string;  // JSON array of attachment URLs
}

/** Status event from a chat platform */
export interface StatusEvent {
  type: 'status';
  platform: string;
  status: 'connected' | 'disconnected' | 'error' | 'ready';
  data?: string;
}

/** Outbound reply from Zig agent → chat platform */
export interface OutboundReply {
  type: 'reply';
  platform: string;
  to: string;
  text: string;
  threadId?: string;
}

/** Outbound voice message */
export interface OutboundVoice {
  type: 'voice';
  platform: string;
  to: string;
  audio: string; // base64-encoded audio
}

export type OutboundMessage = OutboundReply | OutboundVoice;

/** Chat platform adapter interface — each platform implements this */
export interface ChatAdapter {
  /** Platform identifier (e.g., "discord", "telegram") */
  readonly platform: string;

  /** Connect to the platform. Called once at startup. */
  connect(): Promise<void>;

  /** Disconnect cleanly. Called on shutdown. */
  disconnect(): Promise<void>;

  /** Send a text reply to a channel/user */
  sendReply(to: string, text: string, threadId?: string): Promise<void>;

  /** Send a voice message (optional — not all platforms support it) */
  sendVoice?(to: string, audioBase64: string): Promise<void>;
}

/** Callback for when an adapter receives a message */
export type MessageHandler = (msg: InboundMessage) => void;

/** Callback for status events */
export type StatusHandler = (event: StatusEvent) => void;
