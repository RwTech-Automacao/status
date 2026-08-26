/**
 * sessao.js — assinatura e verificação do cookie de sessão
 * ---------------------------------------------------------------------------
 * Compartilhado entre o middleware (que valida) e /api/login (que emite).
 *
 * Não há banco de sessões. O cookie carrega o próprio prazo de validade,
 * assinado com HMAC-SHA256: o servidor confere a assinatura e a data sem
 * precisar guardar nada. Para uma página interna isso basta — e evita
 * arrastar um Redis só para dizer quem está logado.
 *
 * A chave de assinatura é DERIVADA de STATUS_PASS. Duas consequências, as
 * duas desejáveis:
 *   · uma variável de ambiente a menos para configurar (e esquecer);
 *   · trocar a senha invalida todas as sessões abertas, de graça.
 */

const COOKIE = 'sla_sessao';
const DURACAO_S = 12 * 60 * 60;          // 12 horas
const SALT = 'rwtech-status-v1';          // separa este uso de qualquer outro

const enc = new TextEncoder();

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function hmac(mensagem, segredo) {
  const chave = await crypto.subtle.importKey(
    'raw', enc.encode(SALT + '|' + segredo),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(new Uint8Array(
    await crypto.subtle.sign('HMAC', chave, enc.encode(mensagem))));
}

/**
 * `a === b` termina no primeiro caractere diferente, e essa diferença de
 * tempo é observável pela rede. Comparar tudo sempre, acumulando com XOR,
 * fecha o canal. Custa nada num token de 60 bytes.
 */
function igual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function emitirToken(usuario, senha) {
  const expira = Math.floor(Date.now() / 1000) + DURACAO_S;
  const corpo = `${expira}|${usuario}`;
  return `${expira}.${await hmac(corpo, senha)}`;
}

export async function tokenValido(token, usuario, senha) {
  if (!token) return false;
  const p = token.indexOf('.');
  if (p < 1) return false;

  const expira = Number(token.slice(0, p));
  if (!Number.isFinite(expira) || expira < Math.floor(Date.now() / 1000)) return false;

  const esperado = await hmac(`${expira}|${usuario}`, senha);
  return igual(token.slice(p + 1), esperado);
}

export function lerCookie(req, nome = COOKIE) {
  const bruto = req.headers.get('cookie') || '';
  for (const parte of bruto.split(';')) {
    const i = parte.indexOf('=');
    if (i > 0 && parte.slice(0, i).trim() === nome) return parte.slice(i + 1).trim();
  }
  return null;
}

export function cookieDeSessao(token) {
  // HttpOnly  : JavaScript da página não lê -- um XSS não rouba a sessão
  // Secure    : só sobre HTTPS
  // SameSite  : Lax, e não Strict, para que o cookie acompanhe o
  //             redirecionamento vindo do POST de login
  return `${COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${DURACAO_S}`;
}

export function cookieVazio() {
  return `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
}

export { COOKIE, DURACAO_S, igual };
