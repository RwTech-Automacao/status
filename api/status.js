/**
 * /api/status — proxy entre a página e o n8n
 * ---------------------------------------------------------------------------
 * Por que existir, se a página poderia chamar o n8n direto:
 *
 *  1. O SEGREDO NÃO VAZA. O token do webhook vive aqui, no servidor. Se a
 *     página chamasse o n8n direto, o token estaria no JavaScript — visível
 *     para qualquer pessoa que passasse do login. Login com token exposto
 *     é teatro.
 *
 *  2. ACABA O CORS. Mesma origem: a página pede /api/status, não um domínio
 *     de fora. Some a classe inteira de erro mais silenciosa do front.
 *
 *  3. A PÁGINA DE STATUS SOBREVIVE À QUEDA. O `stale-while-revalidate` faz a
 *     borda do Vercel continuar servindo a última resposta boa por 5 minutos
 *     enquanto tenta buscar outra. Se o n8n cair junto com a infra que ele
 *     monitora, a página mostra o último estado conhecido em vez de quebrar
 *     — que é exatamente quando alguém vai olhá-la.
 *
 * Variáveis de ambiente (no painel do Vercel, nunca no repositório):
 *   N8N_STATUS_URL  https://.../webhook/status
 *   N8N_TOKEN       opcional; casa com o Header Auth do nó Webhook
 */

export const config = { runtime: 'edge' };

export default async function handler() {
  const url = process.env.N8N_STATUS_URL;

  if (!url) {
    return json({ erro: 'N8N_STATUS_URL não configurada no Vercel' }, 500);
  }

  try {
    const upstream = await fetch(url, {
      headers: process.env.N8N_TOKEN
        ? { 'x-status-token': process.env.N8N_TOKEN }
        : {},
      // 10s: se o n8n não respondeu até aí, o cache velho é melhor resposta
      signal: AbortSignal.timeout(10_000),
    });

    if (!upstream.ok) {
      return json({ erro: `n8n respondeu ${upstream.status}` }, 502);
    }

    // Repassa o corpo cru. Não reserializar evita perder precisão numérica
    // e evita que um erro de parse aqui derrube uma resposta que estava boa.
    const corpo = await upstream.text();

    return new Response(corpo, {
      headers: {
        'content-type': 'application/json; charset=utf-8',
        // s-maxage: cache da BORDA (compartilhado entre visitantes).
        // stale-while-revalidate: serve o antigo enquanto busca o novo.
        'cache-control': 'public, s-maxage=60, stale-while-revalidate=300',
      },
    });
  } catch (e) {
    return json({ erro: 'n8n inalcançável', detalhe: String(e.message || e) }, 502);
  }
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8',
               'cache-control': 'no-store' },
  });
}
