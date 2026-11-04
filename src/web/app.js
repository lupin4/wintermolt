// Copyright The Fantastic Planet - By David Clabaugh
//
// app.js — the wintermolt --web page. Talks to web/bridge.zig over one
// WebSocket; the protocol is listed at the top of that file. Everything the
// model writes is escaped before it becomes HTML (md() below), and the server's
// CSP runs scripts from this file only.
'use strict';

const $ = (sel) => document.querySelector(sel);
const log = $('#log');
const scroller = $('#scroll');
const input = $('#input');
const sendBtn = $('#send');
const modelBtn = $('#model');
const panel = $('#panel');
const panelBody = $('#panel-body');

const state = {
  ws: null,
  everOpened: false,   // this page has had a working socket
  attemptOpened: false,
  retry: 0,
  running: null,       // id of the message in flight
  replies: new Map(),
  sent: [],            // what you typed, for ArrowUp
  recall: -1,
  image: null,
  panel: null,
  editing: null,       // workspace file open in the editor
  savedNote: '',
  seq: 0,
};

// ── The token: wintermolt prints a link ending in #token=… ───────────────
function getToken() {
  const fromLink = new URLSearchParams(location.hash.slice(1)).get('token');
  if (fromLink) {
    try { localStorage.setItem('wintermolt-token', fromLink); } catch (_) {}
    history.replaceState(null, '', location.pathname); // keep it out of the address bar
    return fromLink;
  }
  try { return localStorage.getItem('wintermolt-token'); } catch (_) { return null; }
}

function showGate() {
  setModel('not connected', 'off');
  if ($('#gate')) return;
  const g = document.createElement('div');
  g.className = 'gate';
  g.id = 'gate';
  g.innerHTML = '<p>This page needs the link wintermolt printed when it started. It ends in <code>#token=</code>. Open that link, or run <code>wintermolt --web</code> again for a new one.</p>';
  log.appendChild(g);
}

// ── Connection ───────────────────────────────────────────────────────────
function connect() {
  if (state.ws && state.ws.readyState <= WebSocket.OPEN) return; // a retry timer and hashchange can race
  const token = getToken();
  if (!token) return showGate();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws?token=${encodeURIComponent(token)}`);
  state.ws = ws;
  state.attemptOpened = false;
  ws.onopen = () => {
    state.everOpened = true;
    state.attemptOpened = true;
    state.retry = 0;
    const gate = $('#gate');
    if (gate) gate.remove();
    if (state.panel) requestPanel(state.panel);
  };
  ws.onmessage = (e) => {
    let m;
    try { m = JSON.parse(e.data); } catch (_) { return; }
    handle(m);
  };
  ws.onclose = () => {
    state.ws = null;
    if (state.running) {
      const r = state.replies.get(state.running);
      if (r) addLine(r, 'error', 'The connection closed before the reply finished.');
      finish(state.running);
    }
    // Refused again and again: wintermolt stopped, or restarted with a new token.
    // Keep trying quietly; the same token (WINTERMOLT_WEB_TOKEN) reconnects by itself.
    state.retry++;
    if (!state.attemptOpened && (!state.everOpened || state.retry > 3)) showGate();
    else setModel('reconnecting', 'off');
    setTimeout(connect, Math.min(8000, 500 * 2 ** state.retry));
  };
}

// A new link opened in this tab carries a new token.
window.addEventListener('hashchange', () => {
  if (!new URLSearchParams(location.hash.slice(1)).get('token')) return;
  if (state.ws) state.ws.close(); else connect();
});

function send(obj) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return false;
  state.ws.send(JSON.stringify(obj));
  return true;
}

function setModel(text, st) {
  modelBtn.textContent = text;
  modelBtn.dataset.state = st || 'on';
}

// ── Incoming ─────────────────────────────────────────────────────────────
function handle(m) {
  switch (m.type) {
    case 'status':
      if (m.busy && !m.model) setModel('busy with another page');
      else setModel(`${m.model} on ${m.backend}`);
      break;
    case 'token': {
      if (typeof m.text !== 'string') break; // not UTF-8: sent as bytes, skipped
      const r = reply(m.id);
      clearWorking(r);
      appendText(r, m.text);
      break;
    }
    case 'tool_start': {
      const r = reply(m.id);
      clearWorking(r);
      r.seg = null; // text after the tool starts a new block
      const row = document.createElement('div');
      row.className = 'tool';
      row.innerHTML = '<b></b> <span>running</span>';
      row.querySelector('b').textContent = m.tool;
      r.el.appendChild(row);
      r.tools.set(m.tool_id, row);
      stick();
      break;
    }
    case 'tool_done': {
      const r = state.replies.get(m.id);
      const row = r && r.tools.get(m.tool_id);
      if (row) {
        row.classList.add(m.ok ? 'done' : 'failed');
        row.querySelector('span').textContent = m.ok ? 'done' : 'failed';
      }
      break;
    }
    case 'notice': // a terminal command's printout: drop its colour codes
      addLine(reply(m.id), 'notice', String(m.text).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, ''));
      break;
    case 'resumed': showResumed(m.items || []); break;
    case 'error':
      if (m.id) addLine(reply(m.id), 'error', explain(m.error));
      else flash(explain(m.error));
      break;
    case 'done':
      finish(m.id);
      break;
    case 'history': renderHistory(m.items || []); break;
    case 'transcript': renderTranscript(m.conversation_id, m.text || ''); break;
    case 'skills': renderSkills(m.items || []); break;
    case 'workspace': renderWorkspace(m.dir, m.files || []); break;
    case 'workspace_file': renderEditor(m.name, m.content || ''); break;
    case 'keys': renderKeys(m.items || []); break;
  }
}

function explain(err) {
  const known = {
    CurlRequestFailed: 'Could not reach the model. Is Ollama running, or is the backend\'s key set?',
    ConnectionRefused: 'Could not reach the model. Is Ollama running?',
    ApiKeyRejected: 'The backend refused its API key. Set it again with wintermolt --keys.',
    EmptyReply: 'The model returned an empty reply twice. Try again, or rephrase.',
    UnknownBackend: 'No backend by that name. /model lists them.',
    MissingApiKey: 'That backend needs an API key. Set it with wintermolt --keys.',
  };
  return known[err] || `Something failed: ${err}. The wintermolt window has the details.`;
}

// ── Transcript ───────────────────────────────────────────────────────────
function reply(id) {
  let r = state.replies.get(id);
  if (!r) {
    const el = document.createElement('div');
    el.className = 'reply';
    log.appendChild(el);
    r = { id, el, seg: null, tools: new Map(), working: null };
    state.replies.set(id, r);
  }
  return r;
}

function clearWorking(r) {
  if (r.working) { r.working.remove(); r.working = null; }
}

/** A reply is blocks of text with tool rows between them; each block renders at most once a frame. */
function appendText(r, t) {
  if (!r.seg) {
    const el = document.createElement('div');
    el.className = 'text';
    r.el.appendChild(el);
    r.seg = { el, text: '', pending: false };
  }
  const seg = r.seg;
  seg.text += t;
  if (seg.pending) return;
  seg.pending = true;
  requestAnimationFrame(() => {
    seg.pending = false;
    seg.el.innerHTML = md(seg.text);
    stick();
  });
}

function addLine(r, cls, text) {
  clearWorking(r);
  const d = document.createElement('div');
  d.className = cls;
  d.textContent = text;
  r.el.appendChild(d);
  r.seg = null;
  stick();
}

function finish(id) {
  const r = state.replies.get(id);
  if (r) {
    clearWorking(r);
    r.el.classList.remove('live');
    if (r.seg) r.seg.el.innerHTML = md(r.seg.text);
  }
  if (state.running === id) {
    state.running = null;
    sendBtn.disabled = false;
    sendBtn.textContent = 'Send';
    input.focus();
  }
}

/** Scroll to the bottom, unless you have scrolled up to read. */
let pinned = true;
scroller.addEventListener('scroll', () => {
  pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
});
function stick() {
  if (pinned) scroller.scrollTop = scroller.scrollHeight;
}

function addYou(text, imageUrl) {
  const d = document.createElement('div');
  d.className = 'you';
  d.textContent = text;
  if (imageUrl) {
    const img = document.createElement('img');
    img.src = imageUrl;
    img.alt = 'Attached image';
    d.appendChild(img);
  }
  log.appendChild(d);
  pinned = true;
  stick();
}

// ── Markdown: escape first, then a small, closed set of constructs ───────
function esc(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function inline(s) {
  let out = '';
  for (const part of s.split(/(`[^`\n]+`)/)) {
    if (part.length > 1 && part[0] === '`' && part.endsWith('`')) {
      out += '<code>' + esc(part.slice(1, -1)) + '</code>';
      continue;
    }
    let h = esc(part);
    h = h.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    h = h.replace(/(^|[\s(])\*([^*\s][^*\n]*?)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
    h = h.replace(/(^|[\s(])_([^_\s][^_\n]*?)_(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
    // Only http(s) links; the URL was escaped with the rest, so it cannot leave the attribute.
    h = h.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
    out += h;
  }
  return out;
}

const LIST = /^\s*([-*+]|\d+[.)])\s+/;
const BLOCK_START = /^\s*(```|~~~|#{1,6}\s|[-*+]\s|\d+[.)]\s|>|\|)/;

function md(src) {
  const lines = src.replace(/\r/g, '').split('\n');
  let html = '';
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    const fence = l.match(/^\s*(```|~~~)/);
    if (fence) {
      const body = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++]);
      i++; // the closing fence (absent while a reply streams in)
      html += '<pre><code>' + esc(body.join('\n')) + '</code></pre>';
      continue;
    }
    if (!l.trim()) { i++; continue; }
    const h = l.match(/^(#{1,6})\s+(.*)/);
    if (h) {
      const n = Math.min(h[1].length + 2, 6);
      html += `<h${n}>${inline(h[2])}</h${n}>`;
      i++;
      continue;
    }
    if (/^\s*(---|\*\*\*|___)\s*$/.test(l)) { html += '<hr>'; i++; continue; }
    if (LIST.test(l)) {
      const ordered = /^\s*\d/.test(l);
      const items = [];
      while (i < lines.length && LIST.test(lines[i])) {
        items.push(lines[i].replace(LIST, ''));
        i++;
        while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !LIST.test(lines[i])) {
          items[items.length - 1] += ' ' + lines[i].trim();
          i++;
        }
      }
      const tag = ordered ? 'ol' : 'ul';
      html += `<${tag}>` + items.map((x) => '<li>' + inline(x) + '</li>').join('') + `</${tag}>`;
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const cells = (s) => s.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(l);
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(cells(lines[i++]));
      html += '<div class="table"><table><thead><tr>' + head.map((c) => '<th>' + inline(c) + '</th>').join('') +
        '</tr></thead><tbody>' + rows.map((r) => '<tr>' + r.map((c) => '<td>' + inline(c) + '</td>').join('') + '</tr>').join('') +
        '</tbody></table></div>';
      continue;
    }
    if (/^\s*>/.test(l)) {
      const q = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ''));
      html += '<blockquote>' + md(q.join('\n')) + '</blockquote>';
      continue;
    }
    const para = [l];
    i++;
    while (i < lines.length && lines[i].trim() && !BLOCK_START.test(lines[i])) para.push(lines[i++]);
    html += '<p>' + para.map(inline).join('<br>') + '</p>';
  }
  return html;
}

// ── Sending ──────────────────────────────────────────────────────────────
function submit() {
  const text = input.value.trim();
  if (state.running || (!text && !state.image)) return;
  if (text === '/skill' || text === '/skills') { // the list belongs in its panel
    input.value = '';
    resize();
    return openPanel('skills');
  }
  const id = `m${++state.seq}-${Date.now().toString(36)}`;
  const msg = { type: 'message', id, text };
  if (state.image) msg.image = { media_type: state.image.media_type, data: state.image.data };
  if (!send(msg)) return flash('Not connected yet.');

  if (/^\/(new|clear)\b/.test(text)) clearLog();
  addYou(text || '(image)', state.image && state.image.url);
  if (text) { state.sent.push(text); state.recall = -1; }
  input.value = '';
  resize();
  setImage(null);

  state.running = id;
  sendBtn.disabled = true;
  sendBtn.textContent = 'Working';
  const r = reply(id);
  r.el.classList.add('live');
  if (!text.startsWith('/')) {
    r.working = document.createElement('div');
    r.working.className = 'working';
    r.working.textContent = 'Working…';
    r.el.appendChild(r.working);
  }
  stick();
}

function clearLog() {
  for (const node of [...log.children]) if (node.id !== 'hero') node.remove();
  state.replies.clear();
}

function resize() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px';
}

input.addEventListener('input', resize);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    submit();
  } else if (e.key === 'ArrowUp' && (input.value === '' || state.recall >= 0) && state.sent.length) {
    e.preventDefault();
    state.recall = state.recall < 0 ? state.sent.length - 1 : Math.max(0, state.recall - 1);
    input.value = state.sent[state.recall];
    resize();
  } else if (e.key === 'ArrowDown' && state.recall >= 0) {
    e.preventDefault();
    state.recall++;
    if (state.recall >= state.sent.length) { state.recall = -1; input.value = ''; } else input.value = state.sent[state.recall];
    resize();
  }
});
sendBtn.addEventListener('click', submit);
$('#new').addEventListener('click', () => { input.value = '/new'; submit(); });
modelBtn.addEventListener('click', () => {
  input.value = '/model ';
  input.focus();
  resize();
});

// ── Images: paste, drop, or pick ─────────────────────────────────────────
function setImage(img) {
  state.image = img;
  $('#attached').classList.toggle('on', !!img);
  $('#thumb').src = img ? img.url : '';
  $('#thumb-name').textContent = img ? img.name : '';
}

function attach(file) {
  if (!file) return;
  if (!/^image\/(png|jpeg|gif|webp)$/.test(file.type)) return flash('Only PNG, JPEG, GIF or WebP images can be attached.');
  if (file.size > 10 * 1024 * 1024) return flash('That image is over 10 MB. Attach a smaller one.');
  const reader = new FileReader();
  reader.onload = () => {
    const url = String(reader.result);
    setImage({ media_type: file.type, data: url.slice(url.indexOf(',') + 1), url, name: file.name || 'pasted image' });
  };
  reader.readAsDataURL(file);
}

$('#attach').addEventListener('click', () => $('#file').click());
$('#file').addEventListener('change', (e) => { attach(e.target.files[0]); e.target.value = ''; });
$('#unattach').addEventListener('click', () => setImage(null));
document.addEventListener('paste', (e) => {
  const file = [...(e.clipboardData ? e.clipboardData.files : [])].find((f) => f.type.startsWith('image/'));
  if (file) { e.preventDefault(); attach(file); }
});
document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', (e) => {
  e.preventDefault();
  attach([...(e.dataTransfer ? e.dataTransfer.files : [])].find((f) => f.type.startsWith('image/')));
});

function flash(text) {
  const d = document.createElement('div');
  d.className = 'error';
  d.textContent = text;
  log.appendChild(d);
  stick();
  setTimeout(() => d.remove(), 6000);
}

// ── Drawer ───────────────────────────────────────────────────────────────
const TITLES = { history: 'History', skills: 'Skills', workspace: 'Workspace', keys: 'Keys' };

function openPanel(name) {
  if (state.panel === name && panel.classList.contains('open')) return closePanel();
  state.panel = name;
  state.editing = null;
  state.savedNote = '';
  $('#panel-title').textContent = TITLES[name];
  for (const b of document.querySelectorAll('.tabs button')) b.setAttribute('aria-pressed', String(b.dataset.panel === name));
  panelBody.innerHTML = '<p>Loading…</p>';
  panel.classList.add('open');
  requestPanel(name);
}

function requestPanel(name) {
  if (!send({ type: name })) panelBody.innerHTML = '<p>Not connected.</p>';
}

function closePanel() {
  panel.classList.remove('open');
  state.panel = null;
  for (const b of document.querySelectorAll('.tabs button')) b.setAttribute('aria-pressed', 'false');
}

for (const b of document.querySelectorAll('.tabs button')) b.addEventListener('click', () => openPanel(b.dataset.panel));
$('#panel-close').addEventListener('click', closePanel);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && state.panel) closePanel(); });

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function ago(t) {
  const ms = t > 1e12 ? t : t * 1000;
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(ms).toLocaleDateString();
}

function renderHistory(items) {
  if (state.panel !== 'history') return;
  panelBody.replaceChildren();
  if (!items.length) {
    panelBody.appendChild(el('p', '', 'No saved conversations yet. They appear here once you have chatted.'));
    return;
  }
  panelBody.appendChild(el('p', '', 'Past conversations, newest first. Open one to read it or carry on with it.'));
  for (const c of items) {
    const b = el('button', 'item');
    b.appendChild(el('strong', '', c.title || 'Untitled'));
    b.appendChild(el('small', '', `${c.messages} ${c.messages === 1 ? 'message' : 'messages'}, ${ago(c.updated_at)}`));
    b.addEventListener('click', () => {
      panelBody.innerHTML = '<p>Loading…</p>';
      send({ type: 'transcript', conversation_id: c.id });
    });
    panelBody.appendChild(b);
  }
}

function renderTranscript(conversationId, text) {
  if (state.panel !== 'history') return;
  panelBody.replaceChildren();
  const actions = el('div', 'actions');
  const resume = el('button', 'primary', 'Continue this conversation');
  resume.addEventListener('click', () => {
    if (state.running) return flash('Wait for the reply to finish first.');
    resume.disabled = true;
    resume.textContent = 'Continuing…';
    send({ type: 'resume', id: `r${++state.seq}`, conversation_id: conversationId });
  });
  const back = el('button', '', 'Back to the list');
  back.addEventListener('click', () => requestPanel('history'));
  actions.append(resume, back);
  panelBody.appendChild(actions);
  const t = el('div', 'transcript reply');
  t.innerHTML = md(text);
  panelBody.appendChild(t);
}

/** An earlier conversation, carried on here: redraw it as the model now sees it. */
function showResumed(items) {
  clearLog();
  const note = el('div', 'notice', 'Continued from History. The model has what was said, not what its tools returned then.');
  log.appendChild(note);
  for (const it of items) {
    if (it.role === 'user') { addYou(it.text); continue; }
    const r = el('div', 'reply');
    const t = el('div', 'text');
    t.innerHTML = md(it.text);
    r.appendChild(t);
    log.appendChild(r);
  }
  closePanel();
  pinned = true;
  stick();
  input.focus();
}

function renderSkills(items) {
  if (state.panel !== 'skills') return;
  panelBody.replaceChildren();
  if (!items.length) {
    const p = el('p');
    p.innerHTML = 'No skills installed. A skill is a folder with a <code>SKILL.md</code>; put one in <code>~/.wintermolt/skills/</code> or <code>./skills/</code>.';
    panelBody.appendChild(p);
    return;
  }
  panelBody.appendChild(el('p', '', 'The model reads one of these when a task fits it. Pick one to use it now.'));
  for (const s of items) {
    const b = el('button', 'item');
    b.appendChild(el('strong', '', s.name));
    b.appendChild(el('small', '', s.description));
    b.appendChild(el('code', '', s.location));
    b.addEventListener('click', () => {
      input.value = `/skill ${s.name} `;
      resize();
      if (window.innerWidth < 640) closePanel();
      input.focus();
    });
    panelBody.appendChild(b);
  }
}

const WORKSPACE_ABOUT = {
  'AGENTS.md': 'How to work: rules, conventions, what to avoid.',
  'SOUL.md': 'Personality, tone and boundaries.',
  'USER.md': 'Who you are and how you like answers.',
  'IDENTITY.md': 'The agent\'s name and how it presents itself.',
  'MEMORY.md': 'Long-term notes. Only your private sessions read it, never a group.',
};

function size(n) {
  return n < 1024 ? `${n} bytes` : `${(n / 1024).toFixed(1)} KB`;
}

function renderWorkspace(dir, files) {
  if (state.panel !== 'workspace' || state.editing) return;
  panelBody.replaceChildren();
  if (state.savedNote) panelBody.appendChild(el('p', 'saved', state.savedNote));
  state.savedNote = '';
  if (!dir) {
    panelBody.appendChild(el('p', '', 'No workspace folder: HOME is not set. Set WINTERMOLT_WORKSPACE_DIR.'));
    return;
  }
  panelBody.appendChild(el('p', '', 'Read into the prompt every turn. Edit them to change how wintermolt works.'));
  panelBody.appendChild(el('div', 'dir', dir));
  for (const f of files) {
    const b = el('button', 'item');
    b.appendChild(el('strong', '', f.name));
    b.appendChild(el('small', '', WORKSPACE_ABOUT[f.name] || ''));
    b.appendChild(el('small', '', f.size == null ? 'Not created yet' : size(f.size)));
    b.addEventListener('click', () => {
      state.editing = { name: f.name, cap: f.cap };
      panelBody.innerHTML = '<p>Loading…</p>';
      send({ type: 'workspace_read', name: f.name });
    });
    panelBody.appendChild(b);
  }
}

function renderEditor(name, content) {
  if (state.panel !== 'workspace' || !state.editing || state.editing.name !== name) return;
  const cap = state.editing.cap;
  panelBody.replaceChildren();
  const box = el('div', 'editor');
  box.appendChild(el('strong', '', name));
  const ta = el('textarea');
  ta.value = content;
  ta.spellcheck = false;
  ta.setAttribute('aria-label', name);
  const count = el('div', 'count');
  const update = () => {
    const n = [...ta.value].length;
    count.textContent = n > cap
      ? `${n.toLocaleString()} characters. Only the first ${cap.toLocaleString()} reach the prompt.`
      : `${n.toLocaleString()} of ${cap.toLocaleString()} characters read each turn.`;
    count.classList.toggle('over', n > cap);
  };
  ta.addEventListener('input', update);
  update();
  const actions = el('div', 'actions');
  const save = el('button', 'primary', 'Save');
  const cancel = el('button', '', 'Cancel');
  save.addEventListener('click', () => {
    state.editing = null;
    state.savedNote = `Saved ${name}.`;
    panelBody.innerHTML = '<p>Saving…</p>';
    send({ type: 'workspace_write', name, content: ta.value });
  });
  cancel.addEventListener('click', () => { state.editing = null; requestPanel('workspace'); });
  actions.append(save, cancel);
  box.append(ta, count, actions);
  panelBody.appendChild(box);
  ta.focus();
}

function renderKeys(items) {
  if (state.panel !== 'keys') return;
  panelBody.replaceChildren();
  panelBody.appendChild(el('p', '', 'Which keys wintermolt has. This page never shows a key. Change them with wintermolt --keys in a terminal.'));
  for (const k of items) {
    const row = el('div', 'keyrow');
    row.appendChild(el('span', '', k.label));
    row.appendChild(el('span', k.set ? 'set' : 'unset', k.set ? 'Set' : 'Not set'));
    panelBody.appendChild(row);
  }
}

// ── The banner, painted by role as in the TUI ────────────────────────────
const ROLE_CLASS = { A: 'ra', P: 'rp', S: 'rs', F: 'rf', M: 'rm', W: 'rw' };
let art = null;

async function loadArt() {
  try {
    const get = (p) => fetch(p).then((r) => (r.ok ? r.text() : Promise.reject(r.status)));
    const [ft, fr, wt, wr] = await Promise.all(['/banner/full.txt', '/banner/full.roles', '/banner/wordmark.txt', '/banner/wordmark.roles'].map(get));
    art = { full: [ft, fr], wordmark: [wt, wr] };
    paintArt();
  } catch (_) { /* the page works without it */ }
}

function paintArt() {
  if (!art) return;
  const box = $('#art');
  const avail = box.parentElement.clientWidth;
  const cols = (t) => Math.max(...t.split('\n').map((l) => l.length));
  // A monospace character is about 0.6em wide; pick the largest art that stays readable.
  let [text, roles] = art.full;
  let fontPx = Math.min(13, avail / (cols(text) * 0.6));
  if (fontPx < 7.5) {
    [text, roles] = art.wordmark;
    fontPx = Math.min(13, avail / (cols(text) * 0.6));
  }
  box.style.fontSize = `${Math.max(5, fontPx).toFixed(2)}px`;
  const frag = document.createDocumentFragment();
  let run = '';
  let runRole = null;
  const flush = () => {
    if (!run) return;
    const cls = ROLE_CLASS[runRole];
    if (cls) { const s = document.createElement('span'); s.className = cls; s.textContent = run; frag.appendChild(s); } else frag.appendChild(document.createTextNode(run));
    run = '';
  };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const role = ch === '\n' ? null : roles[i] || ' ';
    if (role !== runRole) { flush(); runRole = role; }
    run += ch;
  }
  flush();
  box.replaceChildren(frag);
}

let resizeTimer = 0;
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(paintArt, 120); });

loadArt();
connect();
input.focus();
