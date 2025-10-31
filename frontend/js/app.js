// Read API endpoint from generated config (window.APP_CONFIG.apiEndpoint)
const API = (window.APP_CONFIG && window.APP_CONFIG.apiEndpoint) || "";
if (!API) {
  alert('API endpoint is not configured. Ensure frontend/config/config.js exists.');
  throw new Error('Missing API endpoint configuration');
}

const chatEl = document.getElementById('chat');
const composerEl = document.getElementById('composer');
const sendBtn = document.getElementById('sendBtn');
const clearBtn = document.getElementById('clearBtn');
const copyBtn = document.getElementById('copyBtn');
const toastEl = document.getElementById('toast');

let messages = loadMessages();
render();
scrollToBottom();

composerEl.focus();
autosize(composerEl);

composerEl.addEventListener('input', () => autosize(composerEl));
composerEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});

sendBtn.addEventListener('click', () => send());
clearBtn.addEventListener('click', () => {
  messages = [];
  saveMessages();
  render();
  showToast('Chat cleared');
});
copyBtn.addEventListener('click', (e) => {
  e.preventDefault();
  const last = [...messages].reverse().find(m => m.role === 'assistant');
  if (!last) { showToast('No assistant answer to copy'); return; }
  navigator.clipboard.writeText(last.text).then(() => showToast('Answer copied'));
});

function loadMessages() {
  try {
    const raw = localStorage.getItem('aws_chat_messages');
    return raw ? JSON.parse(raw) : [];
  } catch (e) { return []; }
}

function saveMessages() {
  try { localStorage.setItem('aws_chat_messages', JSON.stringify(messages)); } catch (e) {}
}

function autosize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 180) + 'px';
}

function scrollToBottom() {
  chatEl.scrollTop = chatEl.scrollHeight;
}

function fmtTime(d) {
  const h = String(d.getHours()).padStart(2, '0');
  const m = String(d.getMinutes()).padStart(2, '0');
  return `${h}:${m}`;
}

function render() {
  chatEl.innerHTML = messages.map(renderMessage).join('');
}

function renderMessage(m) {
  const time = fmtTime(new Date(m.ts || Date.now()));
  const avatar = m.role === 'user' ? 'U' : 'A';
  const roleCls = m.role === 'user' ? 'user' : 'assistant';
  const srcs = m.sources && m.sources.length ? `<div class="sources">${renderSources(m.sources)}</div>` : '';
  return `
    <div class="message ${roleCls}">
      <div class="avatar">${avatar}</div>
      <div>
        <div class="bubble">${escapeHtml(m.text)}</div>
        <div class="meta">
          <span>${m.role === 'user' ? 'You' : 'Assistant'} • ${time}</span>
          ${srcs}
        </div>
      </div>
    </div>
  `;
}

function renderSources(sources) {
  return sources.map(s => {
    if (typeof s === 'string') {
      return `<a class="src" href="#" title="source">${escapeHtml(s)}</a>`;
    }
    const title = s.title || s.url || 'source';
    const url = s.url || '#';
    const score = typeof s.score === 'number' ? ` (${(s.score * 100).toFixed(0)}%)` : '';
    return `<a class="src" href="${escapeAttr(url)}" target="_blank" rel="noopener">${escapeHtml(title)}${score}</a>`;
  }).join('');
}

async function send() {
  const text = composerEl.value.trim();
  if (!text) { return; }

  const userMsg = { role: 'user', text, ts: Date.now() };
  messages.push(userMsg);
  composerEl.value = '';
  autosize(composerEl);
  render();
  scrollToBottom();
  saveMessages();

  setLoading(true);
  try {
    const res = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question: text })
    });
    if (!res.ok) throw new Error('Request failed: ' + res.status);
    const data = await res.json();
    const answer = typeof data.answer === 'string' ? data.answer : JSON.stringify(data);
    const sources = Array.isArray(data.sources) ? data.sources : [];
    const botMsg = { role: 'assistant', text: answer, sources, ts: Date.now() };
    messages.push(botMsg);
    render();
    scrollToBottom();
    saveMessages();
  } catch (e) {
    showToast('Error: ' + (e && e.message ? e.message : 'Unknown error'));
  } finally {
    setLoading(false);
  }
}

function setLoading(isLoading) {
  if (isLoading) {
    sendBtn.setAttribute('disabled', 'true');
    sendBtn.classList.add('loading');
  } else {
    sendBtn.removeAttribute('disabled');
    sendBtn.classList.remove('loading');
  }
}

function showToast(msg) {
  toastEl.textContent = msg;
  toastEl.style.display = 'block';
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => { toastEl.style.display = 'none'; }, 2500);
}

function escapeHtml(str) {
  return String(str)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function escapeAttr(str) {
  return String(str).replaceAll('"', '&quot;');
}


