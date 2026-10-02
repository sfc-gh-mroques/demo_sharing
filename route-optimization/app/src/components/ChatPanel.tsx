'use client';
import { useState, useRef, useEffect } from 'react';

function renderMarkdown(text: string): string {
  let html = text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/^(\|.+\|)$/gm, (line) => {
      const cells = line.split('|').filter(c => c.trim() !== '');
      if (cells.every(c => /^[\s-:]+$/.test(c))) return '';
      const tds = cells.map(c => `<td class="px-2 py-1 border border-gray-600">${c.trim()}</td>`).join('');
      return `<tr>${tds}</tr>`;
    })
    .replace(/((?:<tr>.*<\/tr>\n?)+)/g, '<table class="text-xs border-collapse border border-gray-600 my-2">$1</table>')
    .replace(/\n/g, '<br/>');
  return html;
}

interface Message {
  role: 'user' | 'assistant';
  content: string;
}

interface ChatPanelProps {
  open: boolean;
  onClose: () => void;
}

export default function ChatPanel({ open, onClose }: ChatPanelProps) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  async function handleSend() {
    if (!input.trim() || loading) return;
    const userMsg = input.trim();
    setInput('');
    setMessages((prev) => [...prev, { role: 'user', content: userMsg }]);
    setLoading(true);

    try {
      const res = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: userMsg }),
      });
      const text = await res.text();
      let reply: string;
      try {
        const data = JSON.parse(text);
        reply = data.response || data.error || 'Pas de réponse.';
      } catch {
        reply = `Erreur serveur: ${text.substring(0, 200)}`;
      }
      setMessages((prev) => [...prev, { role: 'assistant', content: reply }]);
    } catch (e: any) {
      setMessages((prev) => [...prev, { role: 'assistant', content: `Erreur: ${e.message}` }]);
    } finally {
      setLoading(false);
    }
  }

  if (!open) return null;

  return (
    <div className="fixed right-0 top-0 h-full w-[420px] bg-[#0f1729] border-l border-[#1f2937] shadow-2xl flex flex-col z-[10000]">
      <div className="flex items-center justify-between px-4 py-3 border-b border-[#1f2937]">
        <div className="flex items-center gap-2">
          <div className="w-2 h-2 bg-green-400 rounded-full animate-pulse" />
          <span className="text-sm font-semibold text-white">Agent Fleet Intelligence</span>
        </div>
        <button onClick={onClose} className="text-gray-400 hover:text-white text-lg">&times;</button>
      </div>
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
        {messages.length === 0 && (
          <div className="text-center text-gray-500 text-xs mt-8">
            <p className="mb-2">Posez une question sur vos tournées :</p>
            <div className="space-y-1">
              <p className="text-gray-400 italic">&quot;Combien de commandes GNR ?&quot;</p>
              <p className="text-gray-400 italic">&quot;Quel est le volume total à livrer ?&quot;</p>
              <p className="text-gray-400 italic">&quot;Quels clients sont en zone PICARDIE ?&quot;</p>
            </div>
          </div>
        )}
        {messages.map((msg, i) => (
          <div key={i} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
            <div
              className={`max-w-[85%] px-3 py-2 rounded-lg text-sm ${
                msg.role === 'user'
                  ? 'bg-sf-blue text-white whitespace-pre-wrap'
                  : 'bg-[#1f2937] text-gray-200'
              }`}
              dangerouslySetInnerHTML={msg.role === 'assistant' ? { __html: renderMarkdown(msg.content) } : undefined}
            >
              {msg.role === 'user' ? msg.content : undefined}
            </div>
          </div>
        ))}
        {loading && (
          <div className="flex justify-start">
            <div className="bg-[#1f2937] px-3 py-2 rounded-lg">
              <div className="flex gap-1">
                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" />
                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-150" />
                <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce delay-300" />
              </div>
            </div>
          </div>
        )}
        <div ref={messagesEndRef} />
      </div>
      <div className="px-4 py-3 border-t border-[#1f2937]">
        <div className="flex gap-2">
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleSend()}
            placeholder="Poser une question..."
            className="flex-1 bg-[#1f2937] border border-[#374151] rounded-lg px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-sf-blue"
            disabled={loading}
          />
          <button
            onClick={handleSend}
            disabled={loading || !input.trim()}
            className="bg-sf-blue hover:bg-blue-600 disabled:opacity-50 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
          >
            Envoyer
          </button>
        </div>
      </div>
    </div>
  );
}
