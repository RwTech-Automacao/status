/**
 * /api/picos — proxy da tela operacional
 * ---------------------------------------------------------------------------
 * Mesmo desenho de /api/status, com duas diferenças que importam:
 *
 *  1. REPASSA A QUERYSTRING. É o que faz os filtros funcionarem: ?janela=ontem
 *     ou ?de=...&ate=... chegam até picos_json_req() no banco. Quem resolve
 *     "ontem" é o Postgres, em America/Sao_Paulo -- se a página resolvesse,
 *     dois colegas em fusos diferentes veriam "ontens" diferentes no mesmo
 *     link.
 *
 *  2. NÃO CACHEIA. A resposta traz todos os ambientes e a mensagem crua da
 *     AWS -- inclusive nome de pessoa e versão interna. Isso não pode ficar
 *     numa borda compartilhada. E o conteúdo varia por parâmetro, então
 *     cache renderia pouco de todo modo.
 *
 * A proteção real é o middleware: /api/* exige sessão. Este arquivo confia
 * nisso e não repete a checagem -- duas autenticações em série divergem com
 * o tempo, e a que fica desatualizada é a que abre o buraco.
 */

export const config = { runtime: 'edge' };

const PARAMS = ['janela', 'de', 'ate'];

export default async function handler(req) {
  const base = process.env.N8N_PICOS_URL
            || (process.env.N8N_STATUS_URL || '').replace(/\/status$/, '/picos');

  if (!base) {
    return json({ erro: 'N8N_PICOS_URL não configurada no Vercel' }, 500);
  }

  // Copia só os parâmetros conhecidos. Repassar a querystring inteira
  // deixaria qualquer um empurrar campos para dentro do jsonb que vai
  // ao banco -- o SQL é parametrizado, mas a superfície não precisa
  // existir para começo de conversa.
  const entrada = new URL(req.url).searchParams;
  const alvo = new URL(base);
  for (const p of PARAMS) {
    const v = entrada.get(p);
    if (v) alvo.searchParams.set(p, v.slice(0, 40));
  }

  try {
    const upstream = await fetch(alvo, {
      headers: process.env.N8N_TOKEN ? { 'x-status-token': process.env.N8N_TOKEN } : {},
      signal: AbortSignal.timeout(15_000),
    });

    if (!upstream.ok) return json({ erro: `n8n respondeu ${upstream.status}` }, 502);

    return new Response(await upstream.text(), {
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
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
