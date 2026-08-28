// Roda o picos.js real contra um DOM simulado e um payload real de
// picos_json_req(). Cobre render, gráfico, ranking, filtros e o desvio
// para o login quando a sessão expira.
import fs from 'node:fs';

const script  = fs.readFileSync(import.meta.dirname + '/public/picos.js', 'utf8');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^﻿/, ''));

let falhas = 0;
const ok = (caso, cond, extra) => {
  if (cond) console.log('ok  ' + caso + (extra !== undefined ? '  (' + extra + ')' : ''));
  else { falhas++; console.log('FALHOU ' + caso + (extra !== undefined ? '  -> ' + extra : '')); }
};

const IDS = ['grafico','balde','ranking','eventos','ev-conta','erro','conteudo',
             'p-rotulo','p-picos','p-fora','p-afetados','p-quedas',
             'eixo-de','eixo-ate','de','ate','filtros','aplicar','frescor'];

function rodar(resposta, opts = {}) {
  const el = {}, chips = [];
  for (const j of ['1h','3h','6h','24h','hoje','ontem','7d','30d']) {
    chips.push({ dataset: { janela: j }, _attrs: {},
                 setAttribute(k, v) { this._attrs[k] = v; } });
  }
  const novo = id => ({ id, innerHTML: '', textContent: '', value: '',
                        className: '',
                        classList: { _escureceu: false,
                                     add(c){ if (c === 'carregando') this._escureceu = true; },
                                     remove(){} },
                        addEventListener(){}, hidden: false });
  for (const id of IDS) el[id] = novo(id);

  const doc = {
    getElementById: id => (el[id] ??= novo(id)),
    querySelectorAll: () => chips,
    body: { dataset: {} },
  };
  const loc = { search: opts.search || '', pathname: '/picos', href: '' };
  const pedidos = [];
  const fetchStub = async (url) => {
    pedidos.push(url);
    if (opts.status === 401) return { ok: false, status: 401 };
    if (opts.falha) throw new Error('Failed to fetch');
    return { ok: true, status: 200, json: async () => resposta };
  };

  // setInterval e injetado, nao herdado do Node: alem de deixar os
  // intervalos observaveis, evita que a suite deixe temporizadores vivos
  // e o processo pendurado.
  const timers = [];
  const intervalStub = (fn, ms) => { timers.push(ms); return timers.length; };

  new Function('document','fetch','location','history','addEventListener',
               'URLSearchParams','setInterval', script)(
    doc, fetchStub, loc, { pushState(){} }, () => {}, URLSearchParams, intervalStub);

  return { el, chips, pedidos, loc, timers };
}

try { new Function('document','fetch','location','history','addEventListener','URLSearchParams', script);
      ok('1. picos.js compila', true); }
catch (e) { ok('1. picos.js compila', false, e.message); process.exit(1); }

const tick = () => new Promise(r => setImmediate(r));

(async () => {
  const { el, chips, pedidos, timers } = rodar(payload);
  await tick(); await tick();

  console.log('\n--- pedido ---');
  ok('2.1 usa /api/picos', String(pedidos[0]).startsWith('/api/picos'), pedidos[0]);
  ok('2.2 janela padrao e 3h', String(pedidos[0]).includes('janela=3h'), pedidos[0]);

  console.log('\n--- placar ---');
  ok('2.3 rotulo veio do banco', el['p-rotulo'].textContent === payload.rotulo,
     el['p-rotulo'].textContent);
  ok('2.4 total de picos',  el['p-picos'].textContent === payload.total_picos);
  ok('2.5 total de quedas', el['p-quedas'].textContent === payload.total_quedas);
  ok('2.6 servicos afetados', el['p-afetados'].textContent === payload.componentes_afetados);
  const somaFora = payload.componentes.reduce((a,c) => a + c.fora_de_deploy, 0);
  ok('2.7 soma de fora-de-deploy', el['p-fora'].textContent === somaFora, el['p-fora'].textContent);

  console.log('\n--- grafico ---');
  const g = el.grafico.innerHTML;
  ok('2.8 um grupo por balde',
     (g.match(/<g>/g) || []).length === payload.serie.length,
     (g.match(/<g>/g) || []).length + ' de ' + payload.serie.length);
  ok('2.9 tem linha de base', /<line /.test(g));
  ok('2.10 tooltip descreve o balde', /pico\(s\)/.test(g));
  ok('2.11 legenda do balde', /min$|h$/.test(el.balde.textContent), el.balde.textContent);
  ok('2.12 nenhuma barra estoura a area',
     ![...g.matchAll(/y="(-?[\d.]+)"/g)].some(m => Number(m[1]) < 0));

  console.log('\n--- ranking ---');
  const r = el.ranking.innerHTML;
  ok('2.13 uma linha por componente',
     (r.match(/<tr>/g) || []).length === payload.componentes.length + 1,
     (r.match(/<tr>/g) || []).length - 1);
  const primeiro = payload.componentes[0];
  ok('2.14 ordenado por fora-de-deploy (o pior primeiro)',
     r.indexOf(primeiro.nome) > 0 &&
     payload.componentes.every((c,i,a) => i === 0 || a[i-1].fora_de_deploy >= c.fora_de_deploy),
     primeiro.nome + ' com ' + primeiro.fora_de_deploy);
  ok('2.15 mostra tempo em warning, nao so contagem', /min<\/td>|h<\/td>/.test(r));
  ok('2.16 marca o ambiente', /class="amb prod"/.test(r));

  // Tempo de queda: RELOGIO no estado ruim, nao ponderado. Esta e a tela de
  // operacao -- o que importa e quanto tempo doeu, nao quanto pesa no SLA.
  ok('2.16b tem coluna de tempo fora', /Tempo fora/.test(r));
  ok('2.16b2 tem coluna de warnings', /<th class="n">Warnings<\/th>/.test(r));

  // `warnings` conta TUDO na faixa; `picos` exclui os que aconteceram
  // dentro de uma queda aberta. A diferenca conta outra historia: um
  // servico com 1 pico e 20 warnings nao esta piscando -- esta caindo e
  // oscilando, e o ranking de picos escondia isso.
  const divergem = payload.componentes.filter(c => c.warnings !== c.picos);
  ok('2.16b3 warnings nunca e menor que picos',
     payload.componentes.every(c => c.warnings >= c.picos));
  ok('2.16b4 a diferenca aparece na tela',
     divergem.length === 0 ||
     divergem.every(c => r.includes('>' + c.warnings + '<')),
     divergem.length + ' divergem');
  const comQueda = payload.componentes.filter(c => c.min_em_queda > 0).length;
  ok('2.16c ... preenchida em quem caiu', comQueda === 0 || /min<\/td>|h<\/td>/.test(r), comQueda);

  console.log('\n--- TV: atualiza sozinho ---');
  ok('2.16d recarrega em segundo plano', timers.includes(60000), timers.join(','));
  ok('2.16e ... e checa o frescor mais amiude', timers.includes(10000));
  ok('2.16f marca de frescor com o horario',
     /^atualizado \d{2}:\d{2}$/.test(el.frescor.textContent), el.frescor.textContent);

  console.log('\n--- eventos ---');
  const e = el.eventos.innerHTML;
  ok('2.17 lista os eventos', (e.match(/class="ev"/g) || []).length === payload.eventos.length,
     (e.match(/class="ev"/g) || []).length);
  ok('2.18 avisa o que nao coube',
     el['ev-conta'].textContent.includes('não listados') === (payload.eventos_truncados > 0),
     el['ev-conta'].textContent);
  ok('2.19 marca pico e queda', /t-pico/.test(e) && /t-queda/.test(e));

  console.log('\n--- filtros ---');
  ok('2.20 chip da janela em uso fica marcado',
     chips.filter(c => c._attrs['aria-pressed'] === 'true').length <= 1);
  ok('2.21 campos de periodo preenchidos com a janela atual',
     el.de.value === payload.de.slice(0,16) && el.ate.value === payload.ate.slice(0,16),
     el.de.value + ' .. ' + el.ate.value);

  console.log('\n--- filtro pela URL ---');
  const comOntem = rodar(payload, { search: '?janela=ontem' });
  await tick();
  ok('3.1 le a janela da URL', String(comOntem.pedidos[0]).includes('janela=ontem'),
     comOntem.pedidos[0]);
  const comData = rodar(payload, { search: '?de=2026-08-20T00:00&ate=2026-08-21T00:00' });
  await tick();
  ok('3.2 periodo explicito vence a janela',
     String(comData.pedidos[0]).includes('de=') && String(comData.pedidos[0]).includes('ate=') &&
     !String(comData.pedidos[0]).includes('janela='), comData.pedidos[0]);

  console.log('\n--- falhas ---');
  const expirou = rodar(null, { status: 401 });
  await tick(); await tick();
  ok('4.1 sessao expirada leva ao login', expirou.loc.href.startsWith('/login?next='),
     expirou.loc.href);
  const caiu = rodar(null, { falha: true });
  await tick(); await tick();
  ok('4.2 erro mostra a caixa', caiu.el.erro.hidden === false);
  ok('4.3 erro aponta a variavel certa', /N8N_PICOS_URL/.test(caiu.el.erro.innerHTML));

  console.log('\n--- vazio ---');
  const vazio = rodar({ rotulo:'Ontem', janela:'ontem', de:'2026-08-26T00:00:00',
    ate:'2026-08-27T00:00:00', balde_minutos:60, total_picos:0, total_quedas:0,
    componentes_afetados:0, componentes:[], serie:[], eventos:[], eventos_truncados:0 });
  await tick(); await tick();
  ok('5.1 nao quebra sem dados', !/undefined|NaN/.test(vazio.el.ranking.innerHTML));
  ok('5.2 explica o vazio', /Nenhum pico/.test(vazio.el.ranking.innerHTML));
  ok('5.3 eventos vazios explicados', /Nenhuma transição/.test(vazio.el.eventos.innerHTML));

  console.log(falhas === 0 ? '\n=== PICOS OK ===' : '\n=== ' + falhas + ' FALHA(S) ===');
  process.exit(falhas === 0 ? 0 : 1);
})();
