// Copyright The Fantastic Planet - By David Clabaugh
//
// i18n.zig — Internationalization for UI strings
//
// Comptime string tables for 6 locales: en, ja, zh, ko, es, pt.
// Covers REPL prompts, error messages, help text, status output.
//
// Usage:
//   const msg = i18n.t("greeting", locale);
//   // Returns localized string or English fallback

const std = @import("std");
const compat = @import("../compat.zig");

pub const Locale = enum {
    en,
    ja,
    zh,
    ko,
    es,
    pt,

    pub fn fromString(s: []const u8) Locale {
        if (s.len >= 2) {
            const prefix = s[0..2];
            if (std.mem.eql(u8, prefix, "ja")) return .ja;
            if (std.mem.eql(u8, prefix, "zh")) return .zh;
            if (std.mem.eql(u8, prefix, "ko")) return .ko;
            if (std.mem.eql(u8, prefix, "es")) return .es;
            if (std.mem.eql(u8, prefix, "pt")) return .pt;
        }
        return .en;
    }
};

/// Detect locale from environment.
pub fn detectLocale() Locale {
    if (compat.getenv("WINTERMOLT_LOCALE")) |loc| return Locale.fromString(loc);
    if (compat.getenv("LANG")) |lang| return Locale.fromString(lang);
    if (compat.getenv("LC_ALL")) |lc| return Locale.fromString(lc);
    return .en;
}

/// Translate a key to the given locale. Falls back to English.
pub fn t(key: []const u8, locale: Locale) []const u8 {
    const idx = @intFromEnum(locale);
    for (&translations) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.values[idx];
        }
    }
    // Fallback: return the key itself
    return key;
}

const Entry = struct {
    key: []const u8,
    values: [6][]const u8, // en, ja, zh, ko, es, pt
};

// ---------------------------------------------------------------------------
// Translation table
// ---------------------------------------------------------------------------

const translations = [_]Entry{
    // Greetings and prompts
    .{ .key = "greeting", .values = .{
        "Welcome to Wintermolt",
        "Wintermoltへようこそ",
        "欢迎使用Wintermolt",
        "Wintermolt에 오신 것을 환영합니다",
        "Bienvenido a Wintermolt",
        "Bem-vindo ao Wintermolt",
    } },
    .{ .key = "prompt", .values = .{
        "> ",
        "> ",
        "> ",
        "> ",
        "> ",
        "> ",
    } },
    .{ .key = "goodbye", .values = .{
        "Goodbye.",
        "さようなら。",
        "再见。",
        "안녕히 가세요.",
        "Adiós.",
        "Adeus.",
    } },

    // Status messages
    .{ .key = "conversation_cleared", .values = .{
        "Conversation cleared.",
        "会話がクリアされました。",
        "对话已清除。",
        "대화가 초기화되었습니다.",
        "Conversación borrada.",
        "Conversa limpa.",
    } },
    .{ .key = "history_compacted", .values = .{
        "History compacted.",
        "履歴が圧縮されました。",
        "历史已压缩。",
        "기록이 압축되었습니다.",
        "Historial compactado.",
        "Histórico compactado.",
    } },

    // Errors
    .{ .key = "error_api_key", .values = .{
        "Error: No backend configured. Ensure Ollama is running or set OPENAI_API_KEY.",
        "エラー: バックエンドが設定されていません。Ollamaが実行中か確認してください。",
        "错误：未配置后端。请确保Ollama正在运行。",
        "오류: 백엔드가 구성되지 않았습니다. Ollama가 실행 중인지 확인하세요.",
        "Error: No hay backend configurado. Asegúrese de que Ollama esté en ejecución.",
        "Erro: Nenhum backend configurado. Certifique-se de que o Ollama está em execução.",
    } },
    .{ .key = "error_no_storage", .values = .{
        "No storage available (history disabled).",
        "ストレージが利用できません（履歴無効）。",
        "无可用存储（历史记录已禁用）。",
        "저장소를 사용할 수 없습니다(기록 비활성화됨).",
        "Sin almacenamiento disponible (historial desactivado).",
        "Armazenamento indisponível (histórico desativado).",
    } },

    // Help
    .{ .key = "help_commands", .values = .{
        "Commands:",
        "コマンド:",
        "命令:",
        "명령어:",
        "Comandos:",
        "Comandos:",
    } },
    .{ .key = "help_quit", .values = .{
        "Exit",
        "終了",
        "退出",
        "종료",
        "Salir",
        "Sair",
    } },
    .{ .key = "help_clear", .values = .{
        "Clear conversation history",
        "会話履歴をクリア",
        "清除对话历史",
        "대화 기록 지우기",
        "Borrar historial de conversación",
        "Limpar histórico de conversa",
    } },

    // Chat platforms
    .{ .key = "chat_starting", .values = .{
        "Starting chat mode...",
        "チャットモードを開始中...",
        "正在启动聊天模式...",
        "채팅 모드 시작 중...",
        "Iniciando modo de chat...",
        "Iniciando modo de chat...",
    } },
    .{ .key = "chat_exited", .values = .{
        "Chat sidecar exited",
        "チャットサイドカーが終了しました",
        "聊天侧车已退出",
        "채팅 사이드카가 종료되었습니다",
        "El sidecar de chat ha salido",
        "O sidecar de chat foi encerrado",
    } },

    // TTS
    .{ .key = "tts_synthesizing", .values = .{
        "Synthesizing...",
        "音声合成中...",
        "正在合成...",
        "합성 중...",
        "Sintetizando...",
        "Sintetizando...",
    } },

    // Scheduler
    .{ .key = "no_jobs", .values = .{
        "No jobs scheduled.",
        "スケジュールされたジョブはありません。",
        "没有计划的任务。",
        "예약된 작업이 없습니다.",
        "No hay trabajos programados.",
        "Nenhum trabalho agendado.",
    } },
};
