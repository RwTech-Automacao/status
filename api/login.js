/**
 * /api/login — valida o formulário e abre a sessão
 * ---------------------------------------------------------------------------
 * Recebe o POST de public/login.html, confere as credenciais contra as
 * variáveis de ambiente e devolve um redirecionamento com o cookie de
 * sessão assinado.
 */

import { emitirToken, cookieDeSessao, igual } from '../lib/sessao.js';

export const config = { runtime: 'edge' };

// Atraso fixo em toda tentativa que falha. Não é rate limiting de verdade
// -- para isso seria preciso estado compartilhado entre as bordas -- mas
// derruba a taxa de um ataque de força bruta de milhares para ~2 por
// segundo por conexão, o que já muda a ordem de grandeza do problema.
const ATRASO_ERRO_MS = 500;

export default async function handler(req) {
  if (req.method !== 'POST') {
    return new Response('Método não permitido', { status: 405 });
  }

  const usuarioOk = process.env.STATUS_USER;
  const senhaOk   = process.env.STATUS_PASS ?? '';

  if (!usuarioOk) {
    // Login desligado: não há o que autenticar, manda para a página.
    return redirecionar('/', req);
  }

  let usuario = '', senha = '', destino = '/';
  try {
    const form = await req.formData();
    usuario = String(form.get('usuario') ?? '');
    senha   = String(form.get('senha')   ?? '');
    destino = String(form.get('next')    ?? '/');
  } catch {
    return falhar(destino, req);
  }

  // Compara os dois campos SEMPRE, mesmo com o usuário já errado. Sair mais
  // cedo quando o usuário não existe revela quais usuários existem pelo
  // tempo de resposta.
  const certo = igual(usuario, usuarioOk) & igual(senha, senhaOk);

  if (!certo) {
    await new Promise(r => setTimeout(r, ATRASO_ERRO_MS));
    return falhar(destino, req);
  }

  const resp = redirecionar(seguro(destino), req);
  resp.headers.set('set-cookie', cookieDeSessao(await emitirToken(usuario, senha)));
  return resp;
}

/**
 * Só caminho relativo da própria origem.
 *
 * O login.js já filtra no navegador, mas o POST vem do cliente e pode ser
 * forjado -- validar de novo aqui é o que realmente impede o
 * redirecionamento aberto. A barra dupla importa: "//outro.tld" é URL
 * absoluta para o navegador, mesmo começando com "/".
 */
function seguro(caminho) {
  return /^\/(?!\/)/.test(caminho) ? caminho : '/';
}

function redirecionar(caminho, req) {
  return new Response(null, {
    status: 303,                                  // 303: o POST vira GET
    headers: {
      location: new URL(caminho, req.url).toString(),
      'cache-control': 'no-store',
    },
  });
}

function falhar(destino, req) {
  const url = new URL('/login', req.url);
  url.searchParams.set('erro', '1');
  const d = seguro(destino);
  if (d !== '/') url.searchParams.set('next', d);
  return redirecionar(url.pathname + url.search, req);
}
