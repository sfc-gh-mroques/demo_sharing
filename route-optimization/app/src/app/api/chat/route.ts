import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const { message } = await request.json();
    if (!message || typeof message !== 'string') {
      return NextResponse.json({ error: 'Message is required' }, { status: 400 });
    }

    const contextMessage = `Contexte: tu analyses les résultats d'optimisation de tournées de livraison de carburant. Les tables disponibles sont COMMANDES, DEPOT, CAMION, OPTIMIZATION_RESULTS, et les vues ROUTE_METRICS et ROUTE_KPI. Question: ${message}`;

    const body = JSON.stringify({
      messages: [{ role: 'user', content: [{ type: 'text', text: contextMessage }] }]
    });
    const sqlBody = body.replace(/'/g, "''");

    // Agent name should be configured via env var or customized per deployment
    const agentName = process.env.CORTEX_AGENT_NAME || '';
    if (!agentName) {
      return NextResponse.json({ error: 'Chat agent not configured (set CORTEX_AGENT_NAME env var)' }, { status: 501 });
    }

    const rows = await query(
      `SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('${agentName}', '${sqlBody}') AS response`
    );

    if (rows.length === 0) {
      return NextResponse.json({ error: 'No response from agent' }, { status: 500 });
    }

    const raw = rows[0].RESPONSE;
    const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;

    if (parsed.error_code || parsed.code) {
      return NextResponse.json({ error: parsed.message || 'Agent error' }, { status: 500 });
    }

    let content = '';
    if (parsed.content && Array.isArray(parsed.content)) {
      content = parsed.content
        .filter((item: any) => item.type === 'text')
        .map((item: any) => item.text)
        .join('\n\n');
    } else if (typeof parsed.content === 'string') {
      content = parsed.content;
    } else if (parsed.message) {
      content = parsed.message;
    } else {
      content = JSON.stringify(parsed);
    }

    return NextResponse.json({ response: content || 'Pas de réponse textuelle.' });
  } catch (error: any) {
    console.error('[Chat API] Error:', error.message);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}
