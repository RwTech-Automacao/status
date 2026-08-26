/**
 * middleware.js — portão da página de status
 * ---------------------------------------------------------------------------
 * Roda na borda do Vercel, ANTES de qualquer arquivo ser servido. Protege a
 * página E o /api/status: o proxy precisa ficar atrás do mesmo portão, senão
 * bastaria chamar /api/status direto e o login não valeria nada.
 *
 * Autenticação por FORMULÁRIO, não HTTP Basic. Basic Auth exibe a caixa
 * nativa do navegador, que não é estilizável e não tem como fazer logout.
 * Aqui a tela é nossa e a sessão é um cookie assinado (ver lib/sessao.js).
 *
 * Sem STATUS_USER configurado, o site fica aberto. É deliberado: página
 * pública é o destino final deste projeto (`public_components` existe
 * para isso), e um deploy novo não deve se trancar sozinho.
 *
 * Variáveis de ambiente (painel do Vercel):
 *   STATUS_USER   usuário
 *   STATUS_PASS   senha — também deriva a chave que assina a sessão
 */

import { lerCookie, tokenValido } from './lib/sessao.js';

export const config = {
  matcher: ['/((?!_vercel/insights|favicon\\.ico).*)'],
};

// Rotas que precisam ficar de fora, senão o redirecionamento vira laço:
// quem não está logado é mandado para /login, que também exigiria login.
const ABERTAS = new Set([
  '/login', '/login.html', '/login.js',
  '/api/login', '/api/logout',
]);

export default async function middleware(req) {
  const usuario = process.env.STATUS_USER;
  const senha   = process.env.STATUS_PASS;

  if (!usuario) return;                       // sem credencial = site aberto

  const url = new URL(req.url);
  if (ABERTAS.has(url.pathname)) return;

  if (await tokenValido(lerCookie(req), usuario, senha ?? '')) return;

  // Chamada de dados que expirou merece 401, não uma página de login em
  // HTML -- senão o fetch() da página recebe o formulário como se fosse
  // JSON e o erro que aparece na tela seria um "unexpected token <".
  if (url.pathname.startsWith('/api/')) {
    return new Response(JSON.stringify({ erro: 'sessao expirada' }), {
      status: 401,
      headers: { 'content-type': 'application/json; charset=utf-8',
                 'cache-control': 'no-store' },
    });
  }

  const destino = new URL('/login', url);
  if (url.pathname !== '/') {
    destino.searchParams.set('next', url.pathname + url.search);
  }
  return Response.redirect(destino, 302);
}
