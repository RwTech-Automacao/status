/**
 * n8n Code node — Elastic Beanstalk Environment Health (por e-mail)
 * ---------------------------------------------------------------------------
 * Modo: "Run Once for All Items"  (o IMAP entrega varios e-mails de uma vez)
 *
 * Entra: item do IMAP Email Trigger (ou o mesmo corpo chegando via SNS).
 * Sai:   payload no contrato de ingest_health(jsonb) + `_route` para o Switch.
 *
 * Corpo tipico:
 *
 *   Timestamp: Mon Aug 24 15:11:31 UTC 2026
 *   Message: Environment health has transitioned from Info to Degraded.
 *     Application update in progress on 1 out of 4 instances.
 *   Environment: Api-Fechamento-env
 *   Application: Api-Fechamento-Validacao
 *   NotificationProcessId: 1a2b3c...
 *
 * Aqui NAO existe par ALARM/OK. E uma maquina de estados:
 *   Ok(0) · Info(1) · Unknown(2) · Warning(3) · Degraded(4) · Severe(5)
 * Quem decide o que abre incidente e ingest_health() no banco, comparando com
 * incident_threshold(). O parser so normaliza e entrega.
 *
 * Sem require(): o Code node so libera modulos nativos com
 * NODE_FUNCTION_ALLOW_BUILTIN setado.
 * ---------------------------------------------------------------------------
 */

// "No Data" tem ESPACO no texto da AWS. Comparamos sem separadores para que
// 'No Data', 'no_data' e 'NoData' resolvam todos para o mesmo estado.
const ESTADOS_EB = ['Ok','Info','Pending','Unknown','No Data','Suspended','Warning','Degraded','Severe'];
const CHAVE = s => String(s).toLowerCase().replace(/[\s_-]+/g, '');

// Alternancia explicita em vez de [A-Za-z]+: um estado com espaco quebraria
// a captura e a mensagem inteira seria descartada em silencio.
const RE_TRANSICAO = new RegExp(
  'health has transitioned from\\s+(' + ESTADOS_EB.join('|') + ')' +
  '\\s+to\\s+(' + ESTADOS_EB.join('|') + ')\\b', 'i');

// Avisos de deploy que NAO trazem transicao de saude junto.
const RE_DEPLOY = /new application version was deployed|was deployed to running|environment update completed successfully/i;

function hash64(texto) {
  let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  const s = String(texto);
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 2654435761);
    h2 = Math.imul(h2 ^ c, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (h2 >>> 0).toString(16).padStart(8, '0') + (h1 >>> 0).toString(16).padStart(8, '0');
}

function pular(motivo, extra) {
  return { json: Object.assign({ _route: 'skip', _reason: motivo }, extra || {}) };
}

/* -------------------------------------------------------------------------
 * O corpo do e-mail pode vir em campos diferentes conforme o modo do no IMAP
 * (Simple/RAW) e a versao. Procura o texto puro; se so houver HTML, limpa as
 * tags. Ordem importa: textPlain antes de textHtml.
 * ---------------------------------------------------------------------- */
function limparHtml(html) {
  return html
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h\d)>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
}

/**
 * Devolve { texto, transporte, envelope }.
 *
 * O MESMO aviso do Beanstalk chega por dois caminhos: e-mail (IMAP) e SNS
 * (webhook). O corpo é idêntico -- muda só o invólucro. Saber por qual veio
 * importa para a hora: no e-mail a reserva é a data de recebimento; no SNS
 * é o Timestamp do envelope, que é bem mais próximo do evento real.
 */
function extrairTexto(j) {
  const puro = j.textPlain || j.text || (j.body && j.body.text) || j.snippet;
  if (typeof puro === 'string' && puro.trim()) {
    return { texto: puro, transporte: 'email', envelope: null };
  }

  const html = j.textHtml || j.html || (j.body && j.body.html);
  if (typeof html === 'string' && html.trim()) {
    return { texto: limparHtml(html), transporte: 'email', envelope: null };
  }

  // mesmo corpo chegando por SNS em vez de e-mail
  let env = j.body;
  if (typeof env === 'string') {
    try { env = JSON.parse(env); }
    catch (e) { return { texto: j.body, transporte: 'webhook', envelope: null }; }
  }
  if (env && typeof env.Message === 'string') {
    return { texto: env.Message, transporte: 'sns', envelope: env };
  }
  if (env && typeof env === 'object' && typeof env.message === 'string') {
    return { texto: env.message, transporte: 'webhook', envelope: env };
  }

  return { texto: null, transporte: null, envelope: null };
}

/* -------------------------------------------------------------------------
 * Le o bloco "Chave: valor". O valor de `Message:` costuma quebrar em varias
 * linhas -- por isso o acumulador: uma linha so vira chave nova se casar o
 * padrao no INICIO; o resto e continuacao do valor anterior.
 * ---------------------------------------------------------------------- */
function lerCampos(texto) {
  const campos = {};
  let atual = null;

  for (const bruta of String(texto).split(/\r?\n/)) {
    const linha = bruta.trim();
    const m = linha.match(/^([A-Z][A-Za-z0-9 _-]{2,40}):\s*(.*)$/);

    if (m) {
      atual = m[1].trim().replace(/\s+/g, '');   // "Environment URL" -> "EnvironmentURL"
      campos[atual] = m[2].trim();
    } else if (atual && linha) {
      campos[atual] = (campos[atual] ? campos[atual] + ' ' : '') + linha;
    } else if (!linha) {
      atual = null;                              // linha em branco encerra o valor
    }
  }
  return campos;
}

/* -------------------------------------------------------------------------
 * "Mon Aug 24 15:11:31 UTC 2026" -- formato do Date.toString() do Java, que e
 * o que a AWS manda. new Date() do V8 aceita, mas nao e garantido em todo
 * runtime; um Invalid Date aqui viraria now() no banco e mentiria sobre o
 * inicio do incidente. Por isso o parser explicito, com o nativo como reserva.
 * ---------------------------------------------------------------------- */
const MESES = { Jan:0,Feb:1,Mar:2,Apr:3,May:4,Jun:5,Jul:6,Aug:7,Sep:8,Oct:9,Nov:10,Dec:11 };

function paraIso(valor) {
  if (!valor) return null;
  const t = String(valor).trim();

  const m = t.match(/^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+([A-Z]{2,4})\s+(\d{4})$/);
  if (m && MESES[m[1]] !== undefined && m[6] === 'UTC') {
    return new Date(Date.UTC(+m[7], MESES[m[1]], +m[2], +m[3], +m[4], +m[5])).toISOString();
  }

  const d = new Date(t.replace(/([+-]\d{2})(\d{2})$/, '$1:$2'));
  return isNaN(d.getTime()) ? null : d.toISOString();
}

function normalizarEstado(s) {
  if (!s) return null;
  return ESTADOS_EB.find(e => CHAVE(e) === CHAVE(s)) || null;
}

/* ===================================================================== */
const entrada = (typeof items !== 'undefined') ? items : $input.all();
const saida = [];

for (const item of entrada) {
  const j = item.json || {};

  try {
    const fonte = extrairTexto(j);
    if (!fonte.texto) { saida.push(pular('sem corpo legivel')); continue; }

    const campos = lerCampos(fonte.texto);
    const mensagem = campos.Message || fonte.texto;

    // A frase e a fonte mais confiavel do par de estados; os campos soltos
    // sao o reforco quando o layout do e-mail mudar.
    const transicao = mensagem.match(RE_TRANSICAO);

    const fromState = normalizarEstado(transicao ? transicao[1] : campos.FromState);
    const toState   = normalizarEstado(transicao ? transicao[2] : (campos.ToState || campos.Status));

    // Aviso de deploy sem transicao de saude junto. Nao e ruido: e o unico
    // sinal INEQUIVOCO de deploy no feed -- o resto depende de adivinhar
    // frase dentro da mensagem de saude. Vai para a trilha como marco.
    const marcoDeploy = !toState && RE_DEPLOY.test(mensagem);

    if (!toState && !marcoDeploy) {
      saida.push(pular('e-mail sem transicao de saude reconhecivel',
                       { amostra: String(mensagem).slice(0, 200) }));
      continue;
    }

    const environmentName = campos.Environment || campos.EnvironmentName;
    if (!environmentName) {
      saida.push(pular('e-mail sem Environment'));
      continue;
    }

    // Do CORPO ("Timestamp:"), nunca da hora de entrega: o atraso do IMAP
    // inflaria o MTTR. As reservas dependem do transporte -- o Timestamp do
    // envelope SNS é bem melhor que a data de um e-mail que ficou na fila.
    const doCorpo = paraIso(campos.Timestamp);
    const doEnvelope = fonte.envelope ? paraIso(fonte.envelope.Timestamp) : null;
    const occurredAt = doCorpo || doEnvelope
      || paraIso(j.date || j.receivedDate || (j.metadata && j.metadata.date))
      || new Date().toISOString();

    const timeSource = doCorpo    ? 'body_timestamp'
                     : doEnvelope ? 'sns_envelope'
                     : fonte.transporte === 'email' ? 'email_delivery'
                     : 'webhook_delivery';

    const npid = campos.NotificationProcessId || campos.NotificationProcessID || null;

    saida.push({ json: {
      _route: 'ingest',

      source:      'beanstalk',
      transport:   fonte.transporte,
      eventType:   marcoDeploy ? 'deploy' : 'health',
      occurredAt,
      timeSource,

      environmentName,
      applicationName: campos.Application || campos.ApplicationName || null,

      fromState,
      toState,
      message: mensagem,

      // Dedup natural do Beanstalk. Quando falta, o hash de conteudo cobre.
      notificationProcessId: npid,
      deliveryHash: hash64([environmentName, fromState, toState, occurredAt].join('|')),
    } });

  } catch (e) {
    saida.push(pular(`erro no parser: ${e.message}`));
  }
}

return saida;
