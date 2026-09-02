// =====================================================================
// Tela operacional. Mesma regra da página pública: a página não calcula,
// só desenha. Quem resolve "ontem", escolhe o tamanho do balde e conta os
// picos é o banco — em America/Sao_Paulo. Se a página resolvesse, dois
// colegas em fusos diferentes veriam "ontens" diferentes no mesmo link.
// =====================================================================

const API = '/api/picos';
const PADRAO = '3h';

// A tela fica numa TV. Os dados se renovam sozinhos; a PAGINA nunca
// recarrega -- um F5 periodico perderia o filtro, piscaria e, se a rede
// falhasse no instante errado, deixaria a TV numa tela de erro em branco.
// Aqui, se um refresh falhar, o conteudo anterior continua no ar e o
// relogio do cabecalho denuncia que envelheceu.
const RECARGA_MS = 60000;

// Acima disso, o que esta na tela nao merece mais confianca.
const VELHO_MS = 5 * 60000;

let ultimoOk = null;

const $  = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[<>&"]/g,
  c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c]));

// O servidor manda "2026-08-27T16:25:37" já em BRT, sem fuso. Formatamos a
// string; passar por new Date() faria o navegador reinterpretar como hora
// local e deslocar tudo para quem abrisse de fora.
const partes = s => (s || '').match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/);
const hora   = s => { const m = partes(s); return m && m[4] ? m[4] + ':' + m[5] : '—'; };
const diaHora= s => { const m = partes(s); return m ? `${m[3]}/${m[2]} ${m[4]}:${m[5]}` : '—'; };

function minutos(m){
  if (!m) return '—';
  if (m < 60) return m + ' min';
  const h = Math.floor(m/60), r = m % 60;
  return r ? `${h} h ${r} min` : `${h} h`;
}

// ---------------------------------------------------------------------
// Estado da tela vive na URL: o filtro fica compartilhável e o botão
// voltar do navegador funciona de graça.
// ---------------------------------------------------------------------
function filtroAtual(){
  const u = new URLSearchParams(location.search);
  if (u.get('de') && u.get('ate')) return { de: u.get('de'), ate: u.get('ate') };
  return { janela: u.get('janela') || PADRAO };
}

function irPara(filtro, empurrar = true){
  const u = new URLSearchParams(filtro);
  const url = location.pathname + '?' + u;
  if (empurrar) history.pushState(filtro, '', url);
  carregar();
}

// ---------------------------------------------------------------------
function grafico(serie, balde){
  const svg = $('grafico');
  if (!serie.length) { svg.innerHTML = ''; return; }

  const teto = Math.max(1, ...serie.map(s => s.picos + s.quedas));
  const larg = 1000 / serie.length;
  const w = Math.max(1, larg - 1.5);

  svg.innerHTML = serie.map((s, i) => {
    const x = i * larg;
    const escala = v => (v / teto) * 104;
    const foraDeploy = Math.max(0, s.picos - s.em_deploy);

    const hQ = escala(s.quedas);
    const hD = escala(s.em_deploy);
    const hF = escala(foraDeploy);

    // Empilhado de baixo para cima: queda, deploy, pico fora de deploy.
    let y = 112;
    const pedacos = [];
    for (const [h, cor] of [[hQ,'var(--outage)'], [hD,'#D9DFE9'], [hF,'var(--degraded)']]) {
      if (h > 0) { y -= h; pedacos.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${cor}"/>`); }
    }

    const t = `${diaHora(s.inicio)} — ${s.picos} pico(s)` +
              (s.em_deploy ? `, ${s.em_deploy} em deploy` : '') +
              (s.quedas ? `, ${s.quedas} evento(s) de queda` : '');

    return `<g><title>${esc(t)}</title>${pedacos.join('')}` +
           `<rect x="${x}" y="0" width="${w}" height="120" fill="transparent"/></g>`;
  }).join('') +
  `<line x1="0" y1="112" x2="1000" y2="112" stroke="var(--line)" stroke-width="1"/>`;

  $('balde').textContent = `um traço = ${minutos(balde)}`;
}

// ---------------------------------------------------------------------
function marcaTempo(min, semFim, emCurso){
  const dicas = [];
  if (semFim)  dicas.push(semFim + ' período(s) sem o evento de recuperação — ' +
                          'o tempo mostrado é um piso');
  if (emCurso) dicas.push('ainda em curso — ou o serviço segue assim, ou o ' +
                          'evento de normalização se perdeu');

  const marca = (semFim  ? '<span class="piso">+</span>' : '') +
                (emCurso ? '<span class="curso">↗</span>' : '');

  return '<td class="n num' + (min ? '' : ' mut') + '"' +
         (dicas.length ? ' title="' + esc(dicas.join(' · ')) + '"' : '') + '>' +
         minutos(min) + marca + '</td>';
}

// ---------------------------------------------------------------------
function ranking(comps){
  if (!comps.length) {
    $('ranking').innerHTML = '<div class="aviso">Nenhum pico nesse período.</div>';
    return;
  }
  const teto = Math.max(1, ...comps.map(c => c.fora_de_deploy));

  // Cabeçalho de uma linha só. O que estava errado antes não era o
  // formato: era o espaçamento. Todas as colunas numéricas tinham
  // padding-right:0 e nenhuma à esquerda, então encostavam umas nas
  // outras e o título deixava de apontar para o número embaixo.
  //
  // A ordem segue a leitura: o que aconteceu (picos, com a quebra por
  // deploy), depois warning (quantas e por quanto tempo), depois queda
  // (idem) e por fim quando foi a última vez.
  const COLS = [
    ['Serviço',          'svc'],
    ['Picos',            'n'],
    ['Warnings',         'n'],
    ['Tempo em warning', 'n'],
    ['Quedas',           'n'],
    ['Tempo fora',       'n'],
    ['Último',           'n'],
  ];

  $('ranking').innerHTML =
    '<table class="rank"><thead><tr>' +
      COLS.map(([rotulo, cls]) =>
        '<th' + (cls === 'n' ? ' class="n"' : '') + '>' + rotulo + '</th>').join('') +
    '</tr></thead><tbody>' +
    comps.map(c =>
      '<tr>' +
        '<td><span class="svc">' + esc(c.nome) + '</span>' +
          '<span class="amb' + (c.ambiente === 'producao' ? ' prod' : '') + '">' +
            esc(c.ambiente) + '</span>' +
          '<div class="barra" style="width:' +
            Math.round((c.fora_de_deploy / teto) * 100) + '%;margin-top:6px"></div></td>' +

        '<td class="n num">' + c.picos + '</td>' +

        // `warnings` conta TUDO na faixa; `picos` exclui os que aconteceram
        // dentro de uma queda já aberta. A diferença é a história: 1 pico e
        // 20 warnings não é "piscou", é "caiu e ficou oscilando".
        '<td class="n num' + (c.warnings ? '' : ' mut') + '">' +
          (c.warnings ?? c.picos) + '</td>' +
        // Dois motivos diferentes para o número não ser exato, e a tela
        // distingue porque a ação é outra em cada caso:
        //
        //   +  transição de fim PERDIDA. O tempo está limitado pelo teto,
        //      então é um piso -- o real é maior.
        //   ↗  ainda em curso. Ou o serviço está mesmo assim desde então,
        //      ou o "voltou ao normal" se perdeu. As duas hipóteses pedem
        //      alguém olhando, e é por isso que o marcador existe.
        marcaTempo(c.min_em_warning, c.periodos_sem_fim, c.periodos_em_curso) +

        '<td class="n num' + (c.quedas ? '' : ' mut') + '">' + c.quedas + '</td>' +
        // tempo de RELÓGIO no estado ruim, não ponderado: esta é a tela de
        // operação, onde o que importa é quanto tempo doeu -- não quanto
        // isso pesa no SLA
        '<td class="n num' + (c.min_em_queda ? '' : ' mut') + '">' +
          (c.min_em_queda ? minutos(c.min_em_queda) : '—') + '</td>' +

        '<td class="n num mut">' + hora(c.ultimo) + '</td>' +
      '</tr>').join('') +
    '</tbody></table>';
}

// ---------------------------------------------------------------------
function eventos(evs, truncados){
  $('ev-conta').textContent = truncados
    ? `${evs.length} mais recentes · ${truncados} não listados`
    : `${evs.length} evento(s)`;

  if (!evs.length) {
    $('eventos').innerHTML = '<div class="aviso">Nenhuma transição de saúde nesse período.</div>';
    return;
  }

  $('eventos').innerHTML = evs.map(e => {
    const tag = e.queda ? '<span class="tag t-queda">queda</span>'
              : e.pico  ? '<span class="tag t-pico">pico</span>'
              : e.severidade <= 1 ? '<span class="tag t-ok">normalizou</span>' : '';
    const dep = e.deploy ? '<span class="tag t-deploy">deploy</span>' : '';
    return '<div class="ev">' +
      '<time class="num">' + hora(e.quando) + '</time>' +
      '<div>' +
        '<div class="ev-t">' + tag + dep +
          '<span class="svc">' + esc(e.componente) + '</span>' +
          '<span class="amb' + (e.ambiente === 'producao' ? ' prod' : '') + '">' +
            esc(e.ambiente) + '</span>' +
          '<span class="mut">' + esc(e.de || '?') + ' → ' + esc(e.para) + '</span>' +
        '</div>' +
        (e.mensagem ? '<p class="ev-msg">' + esc(e.mensagem) + '</p>' : '') +
      '</div></div>';
  }).join('');
}

// ---------------------------------------------------------------------
function render(d){
  $('p-rotulo').textContent   = d.rotulo || '—';
  $('p-picos').textContent    = d.total_picos;
  $('p-quedas').textContent   = d.total_quedas;
  $('p-afetados').textContent = d.componentes_afetados;

  const comps = d.componentes || [];
  $('p-fora').textContent = comps.reduce((a,c) => a + c.fora_de_deploy, 0);

  $('eixo-de').textContent  = diaHora(d.de);
  $('eixo-ate').textContent = diaHora(d.ate);

  grafico(d.serie || [], d.balde_minutos);
  ranking(comps);
  eventos(d.eventos || [], d.eventos_truncados || 0);

  // marca o chip ativo e preenche o período com a janela em uso, para
  // "ajustar a partir daqui" não exigir digitar tudo de novo
  const janela = d.janela;
  for (const b of document.querySelectorAll('.chip[data-janela]')) {
    b.setAttribute('aria-pressed', String(b.dataset.janela === janela));
  }
  $('de').value  = (d.de  || '').slice(0, 16);
  $('ate').value = (d.ate || '').slice(0, 16);
}

// ---------------------------------------------------------------------
async function carregar(silencioso){
  const conteudo = $('conteudo');
  // Só escurece quando a pessoa pediu (filtro novo). No refresh de fundo
  // isso viraria uma piscada a cada minuto na TV.
  if (!silencioso) conteudo.classList.add('carregando');
  try{
    const r = await fetch(API + '?' + new URLSearchParams(filtroAtual()));

    if (r.status === 401) {
      location.href = '/login?next=' + encodeURIComponent(location.pathname + location.search);
      return;
    }
    if (!r.ok) throw new Error('HTTP ' + r.status);

    render(await r.json());
    ultimoOk = new Date();
    marcarFrescor();          // na hora, não no próximo tique de 10s
    $('erro').hidden = true;
  }catch(e){
    $('erro').hidden = false;
    $('erro').innerHTML = '<b>Não foi possível carregar os picos.</b>' +
      esc(e.message) + ' — confira se o workflow da API está ativo e se a ' +
      'variável <code>N8N_PICOS_URL</code> aponta para o webhook <code>/picos</code>.';
  }finally{
    conteudo.classList.remove('carregando');
  }
}

// ---------------------------------------------------------------------
$('filtros').addEventListener('click', ev => {
  const b = ev.target.closest('.chip[data-janela]');
  if (b) irPara({ janela: b.dataset.janela });
});

$('aplicar').addEventListener('click', () => {
  const de = $('de').value, ate = $('ate').value;
  if (de && ate) irPara({ de, ate });
});

// botão voltar do navegador
addEventListener('popstate', () => carregar());

// Marca de frescor: numa TV, painel congelado que parece vivo e pior que
// painel apagado -- ninguem desconfia do numero errado.
function marcarFrescor(){
  const el = $('frescor');
  if (!el) return;
  if (!ultimoOk) { el.textContent = 'carregando…'; el.className = 'frescor'; return; }
  const idade = Date.now() - ultimoOk;
  const hh = String(ultimoOk.getHours()).padStart(2,'0');
  const mm = String(ultimoOk.getMinutes()).padStart(2,'0');
  el.textContent = 'atualizado ' + hh + ':' + mm;
  el.className = 'frescor' + (idade > VELHO_MS ? ' velho' : '');
}

carregar();
setInterval(() => carregar(true), RECARGA_MS);
setInterval(marcarFrescor, 10000);
marcarFrescor();
