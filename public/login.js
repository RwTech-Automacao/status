// Duas coisas só, ambas lidas da URL — a página em si é estática.
//
// Fica em arquivo separado (e não inline) porque o CSP é `script-src 'self'`.
// Script inline exigiria 'unsafe-inline', que enfraqueceria a política
// justamente na página onde uma senha é digitada.

const url = new URLSearchParams(location.search);

// 1. mensagem de erro, sinalizada pelo /api/login no redirecionamento
if (url.get('erro')) {
  document.body.dataset.erro = '1';
  const u = document.getElementById('usuario');
  if (u) u.focus();
}

// 2. para onde voltar depois de entrar
//
// Só caminho relativo da própria origem. Sem esta checagem, um link como
// /login?next=https://sitefalso.tld levaria a vítima a digitar a senha aqui
// e ser jogada num clone lá fora -- redirecionamento aberto clássico.
// A barra dupla importa: "//outro.tld" é URL absoluta para o navegador.
const destino = url.get('next') || '';
if (/^\/(?!\/)/.test(destino)) {
  document.getElementById('next').value = destino;
}
