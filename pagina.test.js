// Roda o <script> real do status.html contra um DOM simulado, alimentado
// por um payload real de status_json(). Nao e um navegador, mas exercita
// render(), barras() e o tratamento de erro de verdade.
import fs from 'node:fs';
const script = fs.readFileSync(import.meta.dirname + '/public/app.js', 'utf8');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));



let falhas = 0;
const ok = (caso, cond, extra) => {
  if (cond) console.log('ok  ' + caso + (extra !== undefined ? '  (' + extra + ')' : ''));
  else { falhas++; console.log('FALHOU ' + caso + (extra !== undefined ? '  -> ' + extra : '')); }
};

function rodar(resposta, opts = {}) {
  const el = {};
  const pega = id => (el[id] ??= { innerHTML: '', textContent: '', hidden: false });
  const doc = { getElementById: pega, body: { dataset: {} } };
  const timers = [];
  const fetchStub = async () => {
    if (opts.falha) throw new Error('Failed to fetch');
    return { ok: true, status: 200, json: async () => resposta };
  };
  new Function('document', 'fetch', 'setInterval', script)(
    doc, fetchStub, (f, ms) => timers.push(ms));
  return { el, doc, timers };
}

try { new Function('document', 'fetch', 'setInterval', script); ok('1. o script compila', true); }
catch (e) { ok('1. o script compila', false, e.message); process.exit(1); }

const tick = () => new Promise(r => setImmediate(r));

(async () => {
  const { el, timers } = rodar(payload);
  await tick(); await tick();

  const comps = el.components.innerHTML;
  const incs  = el.incidents.innerHTML;
  const tudo  = comps + incs + el.verdict.innerHTML;

  console.log('\n--- vazamento ---');
  ok('2.1 sem nome de pessoa', !/Douglas/i.test(tudo));
  ok('2.2 sem zona AWS',       !/us-east-1a/i.test(tudo));
  ok('2.3 sem versao interna', !/17\.32_RC1/.test(tudo));
  ok('2.4 sem homologacao',    !/homolog|NAO PODE APARECER/i.test(tudo));

  console.log('\n--- componentes ---');
  const cards = (comps.match(/<article class="comp">/g) || []).length;
  ok('2.5 dois cards publicos', cards === 2, cards);
  ok('2.6 API Fechamento presente', /API Fechamento/.test(comps));
  ok('2.7 uptime em pt-BR', /99,89%/.test(comps),
     (comps.match(/\d+,\d+%/g) || []).slice(0, 2).join(' '));
  // uma barra por dia, altura fixa (modelo Statuspage/Supabase)
  const barras = (comps.match(/<rect x="\d+" y="6" width="8" height="32"/g) || []).length;
  ok('2.8 90 barras por componente', barras === 180, barras);

  console.log('\n--- cores vindas do banco ---');
  ok('2.9 dia de 8400s pintou vermelho', /var\(--outage\)/.test(comps));
  ok('2.10 dia de 375s pintou amarelo',  /var\(--degraded\)/.test(comps));
  ok('2.11 dia sem queda fica VERDE, nao transparente',
     (comps.match(/fill="var\(--ok\)"/g) || []).length > 150,
     (comps.match(/fill="var\(--ok\)"/g) || []).length);
  ok('2.12 dia so com deploy/manutencao continua verde, explicado no tooltip',
     /fora do SLA \(deploy ou manuten\u00e7\u00e3o\)/.test(comps));
  ok('2.12b ... e mais claro, para quem reparar', /opacity="0\.45"/.test(comps));

  console.log('\n--- incidentes ---');
  const arts = (incs.match(/<article class="inc">/g) || []).length;
  ok('2.13 tres incidentes', arts === 3, arts);
  ok('2.14 usa o public_title',       /Indisponibilidade total da API/.test(incs));
  ok('2.15 NAO usa o titulo interno', !/Ambiente Severe/.test(incs));
  ok('2.16 o de deploy foi omitido',  !/Ambiente Degraded/.test(incs));
  ok('2.17 incidente aberto marcado', /class="inc-dur num open"/.test(incs));
  ok('2.18 nota de acompanhamento',   /Reiniciando os workers/.test(incs));
  ok('2.19 duracao 2h20 formatada',   /2 h 20 min/.test(incs));

  console.log('\n--- cabecalho ---');
  ok('2.20 verdito conta os abertos',
     /1 incidente <mark>ativo<\/mark>/.test(el.verdict.innerHTML), el.verdict.innerHTML);
  ok('2.21 uptime agregado', el.agg.textContent === '99,94%', el.agg.textContent);

  // A hora tem que sair da STRING do payload, sem passar por new Date():
  // se o navegador reinterpretasse como hora local, um cliente fora do
  // Brasil veria outro horario. Comparamos com o que o payload traz.
  const esperado = payload.gerado_em.slice(11, 16);
  ok('2.22 hora sem reinterpretar fuso', el.clock.textContent === esperado,
     el.clock.textContent + ' vs ' + esperado);
  ok('2.23 janela e dado, nao texto fixo', el.janela.textContent === 90);
  ok('2.24 caixa de erro escondida', el.erro.hidden === true);
  ok('2.24b farol conta os abertos', el.farol.textContent === '1 incidente em andamento', el.farol.textContent);
  ok('2.25 recarrega a cada 60s', timers[0] === 60000, timers[0]);

  console.log('\n--- banco vazio (o estado de agora) ---');
  const vazio = rodar({ gerado_em: '2026-08-25T17:53:26', fuso: 'America/Sao_Paulo',
    janela_dias: 90, limiar_vermelho_segundos: 3600, estado_geral: 'operational',
    uptime_janela: null, componentes: [], incidentes: [] });
  await tick(); await tick();
  ok('3.1 nao quebra', !/undefined|NaN/.test(vazio.el.components.innerHTML));
  ok('3.2 explica o que fazer', /publish_component/.test(vazio.el.components.innerHTML));
  ok('3.3 uptime nulo vira travessao',
     vazio.el.agg.textContent === '\u2014', JSON.stringify(vazio.el.agg.textContent));
  ok('3.4 diz que nao houve incidente', /Nenhum incidente/.test(vazio.el.incidents.innerHTML));
  ok('3.5 farol nao mente com banco vazio', vazio.el.farol.textContent === 'Aguardando dados', vazio.el.farol.textContent);

  console.log('\n--- API fora do ar ---');
  const erro = rodar(null, { falha: true });
  await tick(); await tick();
  ok('4.1 mostra a caixa de erro', erro.el.erro.hidden === false);
  ok('4.2 aponta a variavel do Vercel', /N8N_STATUS_URL/.test(erro.el.erro.innerHTML));
  ok('4.3 mostra a rota chamada',       /\/api\/status/.test(erro.el.erro.innerHTML));

  console.log(falhas === 0 ? '\n=== PAGINA OK ===' : '\n=== ' + falhas + ' FALHA(S) ===');
  process.exit(falhas === 0 ? 0 : 1);
})();
