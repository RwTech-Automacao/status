// Exercita o portão de autenticação: middleware, /api/login e /api/logout,
// contra os módulos reais. Web Crypto e fetch são nativos no Node 20+, que
// é o mesmo contrato do Edge Runtime do Vercel.
import { emitirToken, tokenValido, cookieDeSessao, cookieVazio } from './lib/sessao.js';
import middleware from './middleware.js';
import login  from './api/login.js';
import logout from './api/logout.js';

let falhas = 0;
const ok = (caso, cond, extra) => {
  if (cond) console.log('ok  ' + caso + (extra !== undefined ? '  (' + extra + ')' : ''));
  else { falhas++; console.log('FALHOU ' + caso + (extra !== undefined ? '  -> ' + extra : '')); }
};

const USER = 'rwtech', PASS = 'senha-forte-123';
process.env.STATUS_USER = USER;
process.env.STATUS_PASS = PASS;

const req = (caminho, opts = {}) => new Request('https://status.rwtech.com.br' + caminho, opts);
const comCookie = (caminho, valor) =>
  req(caminho, { headers: { cookie: 'sla_sessao=' + valor } });

const formulario = (campos) => {
  const f = new FormData();
  for (const [k, v] of Object.entries(campos)) f.append(k, v);
  return req('/api/login', { method: 'POST', body: f });
};

// ---------------------------------------------------------------- token
console.log('--- token de sessao ---');
const bom = await emitirToken(USER, PASS);
ok('1.1 assina e valida', await tokenValido(bom, USER, PASS));
ok('1.2 senha errada nao valida',   !(await tokenValido(bom, USER, 'outra')));
ok('1.3 usuario errado nao valida', !(await tokenValido(bom, 'outro', PASS)));
ok('1.4 token adulterado nao valida',
   !(await tokenValido(bom.slice(0, -3) + 'AAA', USER, PASS)));
ok('1.5 lixo nao valida', !(await tokenValido('nao-e-token', USER, PASS)));
ok('1.6 vazio nao valida', !(await tokenValido('', USER, PASS)));

const expirado = `${Math.floor(Date.now()/1000) - 10}.${bom.split('.')[1]}`;
ok('1.7 expirado nao valida', !(await tokenValido(expirado, USER, PASS)));

ok('1.8 trocar a senha derruba a sessao', !(await tokenValido(bom, USER, PASS + '!')));

const c = cookieDeSessao(bom);
ok('1.9 cookie e HttpOnly',   /HttpOnly/.test(c));
ok('1.10 cookie e Secure',    /Secure/.test(c));
ok('1.11 cookie tem SameSite',/SameSite=Lax/.test(c), 'Lax para sobreviver ao redirect do POST');
ok('1.12 cookie expira',      /Max-Age=43200/.test(c));

// ------------------------------------------------------------ middleware
console.log('\n--- portao ---');
const semLogin = await middleware(req('/'));
ok('2.1 sem cookie -> redireciona', semLogin?.status === 302, semLogin?.status);
ok('2.2 ... para /login', semLogin?.headers.get('location')?.endsWith('/login'),
   semLogin?.headers.get('location'));

const comLogin = await middleware(comCookie('/', bom));
ok('2.3 com cookie valido -> deixa passar', comLogin === undefined);

const cookieRuim = await middleware(comCookie('/', 'forjado.aaa'));
ok('2.4 cookie forjado -> redireciona', cookieRuim?.status === 302);

ok('2.5 /login fica aberta',    (await middleware(req('/login')))    === undefined);
ok('2.6 /login.js fica aberto', (await middleware(req('/login.js'))) === undefined);
ok('2.7 /api/login fica aberto',(await middleware(req('/api/login')))=== undefined);

const apiSemLogin = await middleware(req('/api/status'));
ok('2.8 /api/status protegido', apiSemLogin?.status === 401, apiSemLogin?.status);
ok('2.9 ... responde JSON, nao HTML',
   apiSemLogin?.headers.get('content-type')?.includes('application/json'));

const guardaNext = await middleware(req('/relatorio?dia=2026-08-25'));
ok('2.10 guarda para onde a pessoa ia',
   decodeURIComponent(guardaNext?.headers.get('location') || '').includes('next=/relatorio?dia='),
   guardaNext?.headers.get('location'));

const semCredencial = await (async () => {
  const u = process.env.STATUS_USER; delete process.env.STATUS_USER;
  const r = await middleware(req('/')); process.env.STATUS_USER = u; return r;
})();
ok('2.11 sem STATUS_USER o site fica aberto', semCredencial === undefined);

// ----------------------------------------------------------------- login
console.log('\n--- /api/login ---');
const certo = await login(formulario({ usuario: USER, senha: PASS, next: '/' }));
ok('3.1 credencial correta -> 303', certo.status === 303, certo.status);
const emitido = certo.headers.get('set-cookie');
ok('3.2 emite o cookie', /^sla_sessao=.+HttpOnly/.test(emitido || ''));
ok('3.3 o cookie emitido e aceito pelo portao',
   await tokenValido((emitido || '').split(';')[0].split('=')[1], USER, PASS));

const errado = await login(formulario({ usuario: USER, senha: 'errada', next: '/' }));
ok('3.4 senha errada -> volta com erro',
   errado.headers.get('location')?.includes('/login?erro=1'), errado.headers.get('location'));
ok('3.5 senha errada NAO emite cookie', !errado.headers.get('set-cookie'));

const usuarioErrado = await login(formulario({ usuario: 'ninguem', senha: PASS, next: '/' }));
ok('3.6 usuario errado tambem falha', !usuarioErrado.headers.get('set-cookie'));

// Redirecionamento aberto: sem a checagem, /login?next=//evil.tld levaria a
// pessoa a digitar a senha aqui e ser jogada num clone la fora.
const aberto = await login(formulario({ usuario: USER, senha: PASS, next: '//evil.tld' }));
ok('3.7 bloqueia redirect para //evil.tld',
   new URL(aberto.headers.get('location')).host === 'status.rwtech.com.br',
   aberto.headers.get('location'));
const aberto2 = await login(formulario({ usuario: USER, senha: PASS, next: 'https://evil.tld' }));
ok('3.8 bloqueia redirect absoluto',
   new URL(aberto2.headers.get('location')).host === 'status.rwtech.com.br');

const preserva = await login(formulario({ usuario: USER, senha: PASS, next: '/relatorio' }));
ok('3.9 preserva destino interno',
   aberto && new URL(preserva.headers.get('location')).pathname === '/relatorio',
   new URL(preserva.headers.get('location')).pathname);

ok('3.10 GET nao e aceito', (await login(req('/api/login'))).status === 405);

// ---------------------------------------------------------------- logout
console.log('\n--- /api/logout ---');
const saida = logout(req('/api/logout'));
ok('4.1 redireciona para /login', saida.headers.get('location')?.endsWith('/login'));
ok('4.2 apaga o cookie', /Max-Age=0/.test(saida.headers.get('set-cookie') || ''));
ok('4.3 o cookie apagado nao vale',
   !(await tokenValido(cookieVazio().split(';')[0].split('=')[1], USER, PASS)));

console.log(falhas === 0 ? '\n=== AUTENTICACAO OK ===' : '\n=== ' + falhas + ' FALHA(S) ===');
process.exit(falhas === 0 ? 0 : 1);
