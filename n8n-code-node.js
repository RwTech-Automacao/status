/**
 * n8n Code node — CloudWatch (Telegram + SNS)
 * ---------------------------------------------------------------------------
 * Modo: "Run Once for All Items"  (o IMAP/SNS pode entregar varios de uma vez)
 *
 * Entra: item cru do Telegram Trigger OU do Webhook (assinatura SNS).
 * Sai:   payload plano no contrato de ingest_health(jsonb), mais um campo
 *        `_route` para o Switch decidir o destino:
 *
 *          ingest       -> no Postgres:  select * from ingest_health($1::jsonb)
 *          confirm_sns  -> HTTP Request GET {{ $json.subscribeUrl }}
 *          skip         -> NoOp
 *
 * NAO derivamos slug nem ambiente aqui de proposito. Quem faz isso e
 * split_environment() no banco (discovery.sql). Assim, quando aparecer um
 * sufixo "-uat" novo, e um INSERT em environment_aliases -- nao um deploy do
 * n8n. O parser so entrega `resource` e deixa o banco decidir.
 *
 * Sem require(): o Code node do n8n so libera modulos nativos se
 * NODE_FUNCTION_ALLOW_BUILTIN estiver setado. O hash e implementado aqui.
 * ---------------------------------------------------------------------------
 */

// Opcional (Decisao em aberto no.3): trave o webhook com um token compartilhado.
// Deixe null para desligar. Se usar, mande o header no SNS via "Delivery policy"
// ou ponha o token na querystring do endpoint assinado.
const WEBHOOK_TOKEN = null;   // ex.: 'troque-isto'

const ESTADOS = new Set(['ALARM', 'OK', 'INSUFFICIENT_DATA']);

/* -------------------------------------------------------------------------
 * hash determinista de 64 bits (cyrb64), sem dependencia externa.
 * Calculado sobre o CONTEUDO do evento, nunca sobre o envelope: assim a
 * reentrega do SNS e a reexecucao do n8n produzem o mesmo hash e
 * webhook_deliveries descarta a segunda.
 * ---------------------------------------------------------------------- */
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

/* -------------------------------------------------------------------------
 * O CloudWatch manda StateChangeTime como "2026-08-24T18:11:31.123+0000".
 * ISO 8601 quer "+00:00". O V8 aceita os dois, mas outros runtimes nao --
 * normalizar aqui evita um Invalid Date silencioso que viraria now() no banco
 * e mentiria sobre o inicio da queda.
 * ---------------------------------------------------------------------- */
function paraIso(valor) {
  if (!valor) return null;
  const t = String(valor).trim().replace(/([+-]\d{2})(\d{2})$/, '$1:$2');
  const d = new Date(t);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

/* -------------------------------------------------------------------------
 * "RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao"
 *  └─org─┘   └──plataforma──┘   └───metrica────┘   └─────── recurso ───────┘
 *
 * Corta em " - " (com espacos). O recurso tem hifens internos e nao pode ser
 * quebrado por eles. Le da direita para a esquerda: o recurso e sempre o
 * ultimo pedaco, mesmo que o nome tenha mais segmentos do que o previsto.
 * ---------------------------------------------------------------------- */
function partesDoAlarme(nome) {
  const p = String(nome || '').split(/\s+-\s+/).map(s => s.trim()).filter(Boolean);
  const n = p.length;
  return {
    org:      n >= 4 ? p[0]     : null,
    platform: n >= 3 ? p[n - 3] : null,
    metric:   n >= 2 ? p[n - 2] : null,
    resource: n >= 1 ? p[n - 1] : String(nome || '').trim(),
  };
}

function pular(motivo, extra) {
  return { json: Object.assign({ _route: 'skip', _reason: motivo }, extra || {}) };
}

/* -------------------------------------------------------------------------
 * Monta o payload final. `fingerprint` e o nome COMPLETO do alarme, sem o
 * prefixo de estado -- e o que amarra o [ALARM] ao [OK] depois.
 * ---------------------------------------------------------------------- */
function montar({ estado, nomeAlarme, occurredAt, timeSource, transport,
                  metric, resource, reason, title, awsDimension }) {
  const partes = partesDoAlarme(nomeAlarme);

  return {
    _route: 'ingest',

    source:      'cloudwatch',
    transport,                                   // sns | telegram
    state:       estado,
    fingerprint: nomeAlarme,
    occurredAt,
    timeSource,                                  // fica em health_events.raw

    org:      partes.org,
    platform: partes.platform,
    metric:   metric   || partes.metric,
    resource: resource || partes.resource,

    // Dimensao real do CloudWatch. Nao substitui `resource` -- o nome do
    // alarme e a convencao da casa. Vai junto porque, quando alguem cria um
    // alarme fora do padrao, e o que permite julgar na discovery_inbox.
    awsDimension: awsDimension || null,

    title:  title  || null,
    reason: reason || null,

    // conteudo, nao envelope
    deliveryHash: hash64([nomeAlarme, estado, occurredAt].join('|')),
  };
}

/* =========================================================================
 * Telegram
 *
 * "[OK] RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao"
 *
 * Limitacao da API: bot nao le mensagem de outro bot por padrao. So funciona
 * com Bot-to-Bot Communication Mode ativado no @BotFather + Group Privacy
 * desativado + bot admin do grupo.
 *
 * O `date` do Telegram e a hora da ENTREGA, nao a do evento. Por isso
 * timeSource marca 'telegram_delivery': atraso do Telegram infla o MTTR e
 * isso precisa ficar rastreavel.
 * ====================================================================== */
function doTelegram(j) {
  const msg = j.message || j.channel_post || j.edited_message || j;
  const texto = msg.text || msg.caption || j.text;
  if (!texto) return pular('mensagem do Telegram sem texto');

  const m = String(texto).match(/^\s*\[([A-Za-z_ ]+)\]\s*(.+?)\s*$/s);
  if (!m) return pular('texto sem prefixo [ESTADO]', { texto: String(texto).slice(0, 200) });

  const estado = m[1].trim().toUpperCase().replace(/\s+/g, '_');
  if (!ESTADOS.has(estado)) return pular(`estado desconhecido: ${estado}`);

  const nomeAlarme = m[2].split(/\r?\n/)[0].trim();
  if (!nomeAlarme) return pular('sem nome de alarme');

  const occurredAt = msg.date
    ? new Date(Number(msg.date) * 1000).toISOString()
    : new Date().toISOString();

  return { json: montar({
    estado, nomeAlarme, occurredAt,
    timeSource: 'telegram_delivery',   // hora da entrega, nao do evento
    transport: 'telegram',
  }) };
}

function corpoDoWebhook(j) {
  let env = j.body !== undefined ? j.body : j;
  if (typeof env === 'string') {
    try { env = JSON.parse(env); } catch (e) { return null; }
  }
  return (env && typeof env === 'object') ? env : null;
}

function tokenOk(j) {
  if (!WEBHOOK_TOKEN) return true;
  const h = j.headers || {}, q = j.query || {};
  return (h['x-status-token'] || h['X-Status-Token'] || q.token) === WEBHOOK_TOKEN;
}

/* =========================================================================
 * Grafana
 *
 * O alerta chega pelo Grafana, nao pelo SNS -- e o corpo nao tem nada de
 * SNS: sem Type, sem Message, sem AlarmName.
 *
 * O que salva o pareamento e o `ruleName`: ele traz a MESMA convencao de
 * nome dos alarmes ("RWTech - ElasticBeanstalk - EnvironmentHealth -
 * api-tarefa-megas-producao") e e identico entre o [Alerting] e o [OK].
 * Serve de fingerprint sem adaptacao -- e, de quebra, o mesmo alarme
 * chegando por Telegram cai no MESMO incidente.
 *
 * LIMITACAO que precisa ficar visivel: o formato legado do Grafana NAO
 * manda hora do evento. O melhor disponivel e a hora da entrega, que para
 * um webhook e quase a hora real -- mas nao e ela. Por isso timeSource
 * marca 'grafana_delivery': o atraso fica rastreavel em vez de virar
 * precisao imaginaria.
 * ====================================================================== */
const ESTADO_GRAFANA = {
  alerting: 'ALARM',
  ok:       'OK',
  no_data:  'INSUFFICIENT_DATA',
  nodata:   'INSUFFICIENT_DATA',
};

function ehGrafana(j, env) {
  const ua = String((j.headers || {})['user-agent'] || '');
  if (/grafana/i.test(ua)) return true;
  if (!env) return false;
  // formato legado tem ruleName+state; o unificado tem alerts[]
  return Boolean((env.ruleName && env.state) || Array.isArray(env.alerts));
}

function doGrafana(j, env) {
  if (!tokenOk(j)) return pular('token invalido');

  // ---- Grafana 9+ (alerting unificado): traz startsAt, hora de verdade ----
  if (Array.isArray(env.alerts) && env.alerts.length) {
    return env.alerts.map(a => {
      const rot = (a.labels && (a.labels.alertname || a.labels.rulename)) || env.title;
      if (!rot) return pular('alerta do Grafana sem nome');

      const disparando = String(a.status || env.status || '').toLowerCase() === 'firing';
      const quando = paraIso(disparando ? a.startsAt : a.endsAt) || new Date().toISOString();

      return { json: montar({
        estado: disparando ? 'ALARM' : 'OK',
        nomeAlarme: String(rot).trim(),
        occurredAt: quando,
        timeSource: 'grafana_startsAt',
        transport: 'grafana',
        metric: a.labels && a.labels.metric,
        reason: (a.annotations && (a.annotations.summary || a.annotations.description)) || null,
        awsDimension: a.labels && (a.labels.EnvironmentName || a.labels.environmentname),
      }) };
    });
  }

  // ---- formato legado (o que a KXC esta mandando hoje) ----
  const estado = ESTADO_GRAFANA[String(env.state || '').toLowerCase()];
  if (!estado) return pular(`estado do Grafana ignorado: ${env.state}`);

  const nomeAlarme = String(env.ruleName || env.title || '').trim()
    // o title vem com o prefixo "[Alerting] "/"[OK] "; o ruleName nao.
    // Tirar o prefixo e o que mantem o fingerprint igual nos dois estados.
    .replace(/^\[[^\]]+\]\s*/, '');

  if (!nomeAlarme) return pular('alerta do Grafana sem ruleName');

  // evalMatches vem preenchido no alerting e VAZIO no ok -- por isso o
  // opcional em tudo aqui.
  const m = Array.isArray(env.evalMatches) && env.evalMatches.length ? env.evalMatches[0] : null;
  const tags = (m && m.tags) || {};

  return { json: montar({
    estado,
    nomeAlarme,
    occurredAt: new Date().toISOString(),
    timeSource: 'grafana_delivery',        // o legado nao manda hora do evento
    transport: 'grafana',
    metric: m && m.metric,
    reason: m ? `${m.metric || 'valor'} = ${m.value}` : null,
    awsDimension: tags.EnvironmentName || tags.environmentName || null,
  }) };
}

/* =========================================================================
 * SNS via Webhook
 *
 * Pegadinha: o SNS posta com Content-Type "text/plain; charset=UTF-8", entao
 * o n8n costuma entregar `body` como STRING, nao objeto. Tratamos os dois.
 * ====================================================================== */
function doSns(j, env) {
  if (!tokenOk(j)) return pular('token invalido');
  if (!env) return pular('corpo nao e JSON');
  {

  const tipo = env.Type || env.type;

  // Assinatura nova: precisa de um GET no SubscribeURL para confirmar.
  if (tipo === 'SubscriptionConfirmation') {
    return { json: {
      _route: 'confirm_sns',
      subscribeUrl: env.SubscribeURL,
      topicArn: env.TopicArn,
    } };
  }

  if (tipo === 'UnsubscribeConfirmation') return pular('UnsubscribeConfirmation');
  if (tipo && tipo !== 'Notification') return pular(`tipo SNS ignorado: ${tipo}`);

  let corpo = env.Message;
  if (typeof corpo === 'string') {
    try { corpo = JSON.parse(corpo); } catch (e) { corpo = null; }
  }
  if (!corpo || !corpo.AlarmName) {
    return pular('Notification que nao e alarme do CloudWatch');
  }

  const estado = String(corpo.NewStateValue || '').toUpperCase();
  if (!ESTADOS.has(estado)) return pular(`estado desconhecido: ${estado}`);

  // StateChangeTime e a hora REAL do evento -- a razao de o SNS ser o
  // transporte preferido. Se faltar, cai para o Timestamp do envelope.
  const occurredAt = paraIso(corpo.StateChangeTime) || paraIso(env.Timestamp);
  const temHoraReal = Boolean(paraIso(corpo.StateChangeTime));

  const dim = (corpo.Trigger && Array.isArray(corpo.Trigger.Dimensions))
    ? corpo.Trigger.Dimensions.find(d => /environment|instance|loadbalancer|queue/i.test(d.name || ''))
    : null;

  return { json: montar({
    estado,
    nomeAlarme: String(corpo.AlarmName).trim(),
    occurredAt: occurredAt || new Date().toISOString(),
    timeSource: temHoraReal ? 'StateChangeTime' : 'sns_envelope',
    transport: 'sns',
    metric: corpo.Trigger && corpo.Trigger.MetricName,
    reason: corpo.NewStateReason,
    title: corpo.AlarmDescription || null,
    awsDimension: dim ? dim.value : null,
  }) };
  }
}

/* ===================================================================== */
const entrada = (typeof items !== 'undefined') ? items : $input.all();
const saida = [];

for (const item of entrada) {
  const j = item.json || {};
  try {
    // Telegram tem `message`/`channel_post`; webhook tem `body`/`headers`.
    if (j.message || j.channel_post || j.edited_message || j.update_id) {
      saida.push(doTelegram(j));
      continue;
    }

    const env = corpoDoWebhook(j);
    const r = ehGrafana(j, env) ? doGrafana(j, env) : doSns(j, env);

    // doGrafana pode devolver varios itens (formato unificado manda alerts[])
    if (Array.isArray(r)) saida.push(...r); else saida.push(r);
  } catch (e) {
    saida.push(pular(`erro no parser: ${e.message}`));
  }
}

return saida;
