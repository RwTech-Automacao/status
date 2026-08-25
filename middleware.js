/**
 * middleware.js — login da página de status
 * ---------------------------------------------------------------------------
 * Autenticação HTTP Basic, rodando na borda do Vercel, ANTES de qualquer
 * arquivo ser servido. Protege tanto a página quanto /api/status — o proxy
 * fica atrás do mesmo portão, senão o login não valeria nada.
 *
 * Basic Auth é modesto de propósito. Para uma página interna de time
 * pequeno, sobre HTTPS, ele resolve sem trazer banco de usuários, sessão,
 * recuperação de senha e um provedor a mais para manter. Quando a página
 * virar pública (é o destino dela — `public_components` já existe para
 * isso), basta esvaziar STATUS_USER e o portão se abre sozinho.
 *
 * Se um dia precisar de SSO de verdade, o caminho é pôr Cloudflare Access
 * ou o Vercel Authentication na frente — e apagar este arquivo.
 *
 * Variáveis de ambiente (painel do Vercel):
 *   STATUS_USER   usuário
 *   STATUS_PASS   senha
 *
 * Sem STATUS_USER definido, o site fica aberto. É deliberado: a página
 * pública é o objetivo final, e um deploy novo não deve travar sozinho.
 */

export const config = {
  // Tudo, menos os assets internos do Vercel.
  matcher: ['/((?!_vercel|favicon\\.ico).*)'],
};

export default function middleware(req) {
  const usuario = process.env.STATUS_USER;
  const senha   = process.env.STATUS_PASS;

  if (!usuario) return;   // sem credencial configurada = página aberta

  const cabecalho = req.headers.get('authorization') || '';
  const esperado  = 'Basic ' + btoa(`${usuario}:${senha ?? ''}`);

  if (!igual(cabecalho, esperado)) {
    return new Response('Acesso restrito.', {
      status: 401,
      headers: {
        'WWW-Authenticate': 'Basic realm="Status RWTech", charset="UTF-8"',
        'cache-control': 'no-store',
      },
    });
  }
}

/**
 * Comparação de tempo constante.
 *
 * `a === b` sai no primeiro caractere diferente, e essa diferença de tempo
 * é mensurável pela rede. Comparar tudo sempre, acumulando as diferenças
 * com XOR, remove o canal. É barato e a alternativa é uma nota de rodapé
 * numa auditoria futura.
 */
function igual(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
