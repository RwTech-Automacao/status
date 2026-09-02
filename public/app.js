// =====================================================================
// A página não calcula nada. Ela desenha o que /api/status devolveu.
//
// Cor da barra, uptime e duração vêm PRONTOS do banco. É de propósito:
// se a página decidisse o que é "um dia vermelho", ela e o relatório
// interno acabariam discordando na primeira vez que alguém mexesse num
// dos dois. O limiar mora em sla_settings.limiar_vermelho_segundos.
// =====================================================================

const API = '/api/status';

// Igual ao s-maxage do proxy: nao adianta pedir mais rapido do que a
// borda do Vercel esta disposta a revalidar.
const RECARGA_MS = 60000;

// ---------------------------------------------------------------------
// Datas: o servidor JÁ converteu para America/Sao_Paulo e mandou sem
// fuso ("2026-08-25T17:53:26"). Passar isso por new Date() faria o
// navegador reinterpretar como hora local — e quem abrisse a página em
// Lisboa veria 4h de diferença num horário que deveria ser absoluto.
// Por isso formatamos a STRING: sem Date, sem fuso, sem surpresa.
// ---------------------------------------------------------------------
const MES = ['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'];
const partes = s => (s || '').match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/);
const hora = s => { const m = partes(s); return m && m[4] ? m[4] + ':' + m[5] : '—'; };
const dia  = s => { const m = partes(s); return m ? m[3] + ' ' + MES[+m[2]-1] + ' ' + m[1] : '—'; };

function dur(s){
  if(s == null) return 'em aberto';
  if(s < 60)   return s + ' s';
  if(s < 3600) return Math.round(s/60) + ' min';
  const h = Math.floor(s/3600), m = Math.round((s%3600)/60);
  return m ? h + ' h ' + m + ' min' : h + ' h';
}
const pct = n => n == null ? '—' : Number(n).toFixed(2).replace('.',',') + '%';

const LABEL = {operational:'Operacional', degraded:'Degradado',
               partial_outage:'Falha parcial', major_outage:'Fora do ar',
               maintenance:'Manutenção'};
const ESTADO_UPD = {investigating:'Investigando', identified:'Identificado',
                    monitoring:'Monitorando', resolved:'Resolvido'};

// A cor vem do banco; aqui só a tradução para a paleta.
const COR = {vermelho:'var(--dia-fora)', amarelo:'var(--dia-parcial)', ok:'var(--ok)'};

const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[<>&"]/g,
  c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c]));

// ---------------------------------------------------------------------
// Uma barra por dia, altura fixa, cor pelo estado — o modelo do Statuspage
// que a Supabase usa. Verde é o normal; a exceção é que salta aos olhos.
//
// Tinha antes uma linha de base contínua onde a queda "afundava"
// proporcionalmente à duração. Era bonito e dizia mais, mas quem lê uma
// página de status quer a resposta em um relance, e noventa alturas
// diferentes pedem interpretação. A duração não se perdeu: está no
// tooltip de cada dia, que é onde alguém procura o detalhe.
// ---------------------------------------------------------------------
function barras(dias){
  return dias.map((d,i) => {
    // Dia cuja queda ficou toda em deploy ou em máquina reduzida: verde,
    // igual a um dia limpo. Foi consequência esperada de uma decisão
    // deliberada, e a barra é o canal de "precisa de atenção".
    //
    // O evento continua no tooltip -- some da cor, não do registro.
    const soExcluido = !d.segundos && d.segundos_excluidos > 0;

    const cor = COR[d.cor] || 'var(--ok)';

    // Tempo de RELÓGIO afetado, somado das faixas do dia. É diferente do
    // número do SLA porque o SLA é ponderado: 'Degradado' pesa 0,25, então
    // 3h30 degradado entram como 52 min. Mostrar só o ponderado ao lado de
    // "20:30 → 00:00" parece erro; mostrar só o relógio esconderia como a
    // conta é feita. Os dois aparecem quando divergem.
    const relogio = (d.faixas || []).reduce((a, f) => {
      const [h1,m1] = f.de.split(':').map(Number);
      const [h2,m2] = f.ate.split(':').map(Number);
      let s = ((h2*60 + m2) - (h1*60 + m1)) * 60;
      if (s <= 0) s += 86400;          // termina na virada do dia
      return a + s;
    }, 0);

    const noSla = d.segundos;
    const mostraDois = relogio > 0 && Math.abs(relogio - noSla) > 60;

    let t = dia(d.dia) + ' — ';
    if (soExcluido)       t += dur(relogio || d.segundos_excluidos) + ' afetado · não conta no SLA';
    else if (!noSla)      t += 'sem quedas';
    else if (mostraDois)  t += dur(relogio) + ' afetado · ' + dur(noSla) + ' no cálculo do SLA';
    else                  t += dur(noSla) + ' fora';

    // Quebra de linha via String.fromCharCode(10): o <title> do SVG aceita
    // multilinha, mas um "\n" escrito à mão dentro desta string já foi
    // convertido em quebra real por uma edição automatizada e partiu o
    // literal. Assim não há escape para alguém estragar.
    const NL = String.fromCharCode(10);
    for (const f of (d.faixas || [])) {
      t += NL + '   ' + f.de + ' → ' + f.ate + '  ' +
           (LABEL[f.impacto] || f.impacto) +
           (f.conta ? '' : '  (não conta: deploy ou manutenção)');
    }

    return '<g><title>' + esc(t) + '</title>' +
      '<rect x="' + (i*10) + '" y="6" width="8" height="32" rx="2" fill="' + cor + '"/>' +
      '<rect x="' + (i*10 - 1) + '" y="0" width="10" height="44" fill="transparent"/></g>';
  }).join('');
}

// ---------------------------------------------------------------------
function render(d){
  document.body.dataset.overall = d.estado_geral || 'operational';

  const abertos = (d.incidentes || []).filter(i => i.em_aberto).length;
  $('verdict').innerHTML = abertos
    ? (abertos === 1 ? '1 incidente <mark>ativo</mark>'
                     : abertos + ' incidentes <mark>ativos</mark>')
    : 'Todos os sistemas <mark>operacionais</mark>';

  $('clock').textContent = hora(d.gerado_em);
  $('agg').textContent   = pct(d.uptime_janela);
  $('janela').textContent = d.janela_dias;

  // O farol dá a resposta antes de a pessoa ler qualquer número. A cor sai
  // do CSS por data-overall; aqui só o texto.
  const temDados = (d.componentes || []).length > 0;
  const farol = $('farol');
  farol.textContent = abertos
    ? (abertos === 1 ? '1 incidente em andamento' : abertos + ' incidentes em andamento')
    : temDados ? 'Tudo operacional' : 'Aguardando dados';
  farol.className = 'farol' + (temDados || abertos ? '' : ' neutro');

  // ---- componentes ----
  const comps = d.componentes || [];
  $('components').innerHTML = comps.length ? comps.map(c =>
    '<article class="comp">' +
      '<div class="comp-top">' +
        '<span class="comp-name">' + esc(c.nome) + '</span>' +
        '<span class="pill s-' + c.status + '">' + (LABEL[c.status] || c.status) + '</span>' +
        '<span class="comp-uptime num">' + pct(c.uptime) + '</span>' +
      '</div>' +
      '<svg class="seismo" viewBox="0 0 900 44" preserveAspectRatio="none">' +
        barras(c.dias || []) + '</svg>' +
      '<div class="axis"><span>' + d.janela_dias + ' dias atrás</span><span>hoje</span></div>' +
    '</article>').join('')
    : '<div class="aviso"><b>Nenhum componente publicado ainda.</b>' +
      'Os serviços aparecem sozinhos quando o primeiro alarme chega, mas nascem ' +
      'despublicados de propósito — um alarme de teste ou um nome com typo não ' +
      'vira componente público. Para liberar: ' +
      '<code>select publish_component(\'slug\',\'producao\',\'Nome Bonito\');</code></div>';

  // ---- histórico ----
  const incs = d.incidentes || [];
  const porDia = {};
  for(const i of incs) (porDia[dia(i.inicio)] ??= []).push(i);

  $('incidents').innerHTML = incs.length
    ? Object.entries(porDia).map(([dd, lista]) =>
        '<p class="day">' + dd + '</p>' +
        lista.map(i =>
          '<article class="inc">' +
            '<div class="inc-head">' +
              '<span class="inc-title">' + esc(i.titulo) + '</span>' +
              '<span class="inc-dur num ' + (i.em_aberto ? 'open' : '') + '">' +
                dur(i.duracao_segundos) + '</span>' +
            '</div>' +
            '<p class="inc-scope num">' + esc(i.componente) + ' · início ' + hora(i.inicio) +
              (i.fim ? ' · fim ' + hora(i.fim) : '') + '</p>' +
            ((i.atualizacoes || []).length
              ? '<ul class="updates">' + i.atualizacoes.map(u =>
                  '<li class="st-' + u.estado + '"><time class="num">' + hora(u.quando) + '</time>' +
                  '<span><b>' + (ESTADO_UPD[u.estado] || u.estado) + '</b>' + esc(u.texto) + '</span></li>'
                ).join('') + '</ul>'
              : '') +
          '</article>').join('')
      ).join('')
    : '<div class="aviso">Nenhum incidente nos últimos ' + d.janela_dias + ' dias.</div>';
}

// ---------------------------------------------------------------------
async function carregar(){
  try{
    const r = await fetch(API);

    // Sessão de 12h expirada. Sem este desvio, a página ficaria mostrando
    // uma caixa de erro genérica até alguém pensar em recarregar — quando
    // o certo é simplesmente pedir para entrar de novo.
    if(r.status === 401){
      location.href = '/login?next=' + encodeURIComponent(location.pathname);
      return;
    }

    if(!r.ok) throw new Error('HTTP ' + r.status);
    render(await r.json());
    $('erro').hidden = true;
  }catch(e){
    // Erro de CORS chega aqui como "Failed to fetch", sem detalhe — o
    // motivo real só aparece no console do navegador. Por isso a dica.
    $('erro').hidden = false;
    $('erro').innerHTML = '<b>Não foi possível ler o status.</b>' +
      esc(e.message) + ' — confira se o workflow da API está ativo em ' +
      '<code>' + esc(API) + '</code>. Como a chamada é na mesma origem, ' +
      'erro aqui costuma ser o proxy sem alcançar o n8n — confira a variável ' +
      '<code>N8N_STATUS_URL</code> no Vercel e se o workflow da API está ativo.';
  }
}

carregar();
setInterval(carregar, RECARGA_MS);
