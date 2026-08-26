/**
 * /api/logout — encerra a sessão
 *
 * Existe porque HTTP Basic não tinha jeito de sair: a única saída era
 * fechar o navegador. Com cookie, sair é apagar o cookie.
 */

import { cookieVazio } from '../lib/sessao.js';

export const config = { runtime: 'edge' };

export default function handler(req) {
  return new Response(null, {
    status: 303,
    headers: {
      location: new URL('/login', req.url).toString(),
      'set-cookie': cookieVazio(),
      'cache-control': 'no-store',
    },
  });
}
