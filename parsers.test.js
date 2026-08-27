import fs from 'node:fs';
const path = import.meta.dirname + '/';

// Os Code nodes terminam com `return saida;` no topo -- e exatamente como o
// n8n os executa. Reproduzimos isso com new Function, injetando `items`.
function carregar(arquivo) {
  const src = fs.readFileSync(path + arquivo, 'utf8');
  const fn = new Function('items', src);
  return (entrada) => fn(entrada.map(json => ({ json })));
}

const cw = carregar('n8n-code-node.js');
const eb = carregar('n8n-code-beanstalk.js');

let falhas = 0;
function ok(caso, obtido, esperado) {
  const a = JSON.stringify(obtido), b = JSON.stringify(esperado);
  if (a !== b) { falhas++; console.log(`FALHOU [${caso}]\n   obtido=${a}\n   esperado=${b}`); }
  else console.log(`ok  ${caso}  (${a})`);
}

const NOME = 'RWTech - ElasticBeanstalk - EnvironmentHealth - api-tarefa-megas-producao';

// ===================== CloudWatch / Telegram =====================
console.log('\n--- Telegram ---');
const tgAlarm = cw([{ message: { text: `[ALARM] ${NOME}`, date: 1787579491 } }])[0].json;
ok('tg.1 rota', tgAlarm._route, 'ingest');
ok('tg.2 estado', tgAlarm.state, 'ALARM');
ok('tg.3 fingerprint SEM o prefixo de estado', tgAlarm.fingerprint, NOME);
ok('tg.4 org', tgAlarm.org, 'RWTech');
ok('tg.5 plataforma', tgAlarm.platform, 'ElasticBeanstalk');
ok('tg.6 metrica', tgAlarm.metric, 'EnvironmentHealth');
ok('tg.7 recurso com hifens intactos', tgAlarm.resource, 'api-tarefa-megas-producao');
ok('tg.8 hora da entrega marcada como tal', tgAlarm.timeSource, 'telegram_delivery');

const tgOk = cw([{ message: { text: `[OK] ${NOME}`, date: 1787579791 } }])[0].json;
ok('tg.9 fingerprint IDENTICO entre ALARM e OK', tgOk.fingerprint === tgAlarm.fingerprint, true);
ok('tg.10 hash difere (estado + hora diferentes)', tgOk.deliveryHash !== tgAlarm.deliveryHash, true);

const tgId = cw([{ message: { text: `[INSUFFICIENT_DATA] ${NOME}`, date: 1787579891 } }])[0].json;
ok('tg.11 INSUFFICIENT_DATA passa', tgId.state, 'INSUFFICIENT_DATA');

ok('tg.12 conversa fiada e descartada',
   cw([{ message: { text: 'bom dia pessoal', date: 1787579891 } }])[0].json._route, 'skip');
ok('tg.13 mensagem sem texto', cw([{ message: { date: 1 } }])[0].json._route, 'skip');

// ===================== CloudWatch / SNS =====================
console.log('\n--- SNS ---');
const alarme = {
  AlarmName: NOME,
  AlarmDescription: 'Saude do ambiente de producao',
  NewStateValue: 'ALARM',
  NewStateReason: 'Threshold Crossed: 1 datapoint [25.0] was greater than the threshold (20.0).',
  StateChangeTime: '2026-08-24T18:11:31.123+0000',
  OldStateValue: 'OK',
  Trigger: { MetricName: 'EnvironmentHealth', Namespace: 'AWS/ElasticBeanstalk',
             Dimensions: [{ name: 'EnvironmentName', value: 'api-tarefa-megas-producao' }] },
};
const envelope = { Type: 'Notification', MessageId: 'm-1', Message: JSON.stringify(alarme),
                   Timestamp: '2026-08-24T18:11:35.000Z' };

const snsObj = cw([{ body: envelope, headers: {} }])[0].json;
ok('sns.1 rota', snsObj._route, 'ingest');
ok('sns.2 hora REAL do evento, nao a do envelope', snsObj.occurredAt, '2026-08-24T18:11:31.123Z');
ok('sns.3 fonte da hora', snsObj.timeSource, 'StateChangeTime');
ok('sns.4 metrica vem do Trigger', snsObj.metric, 'EnvironmentHealth');
ok('sns.5 motivo preservado', snsObj.reason.startsWith('Threshold Crossed'), true);
ok('sns.6 titulo do AlarmDescription', snsObj.title, 'Saude do ambiente de producao');
ok('sns.7 dimensao da AWS junto', snsObj.awsDimension, 'api-tarefa-megas-producao');

// Pegadinha real: o SNS posta com Content-Type text/plain, entao o n8n
// entrega `body` como STRING.
const snsStr = cw([{ body: JSON.stringify(envelope), headers: {} }])[0].json;
ok('sns.8 corpo como STRING funciona igual', snsStr.deliveryHash, snsObj.deliveryHash);

const confirma = cw([{ body: { Type: 'SubscriptionConfirmation',
                               SubscribeURL: 'https://sns.sa-east-1.amazonaws.com/?Action=Confirm',
                               TopicArn: 'arn:aws:sns:...' } }])[0].json;
ok('sns.9 assinatura vai para o ramo de confirmacao', confirma._route, 'confirm_sns');
ok('sns.10 URL preservada', confirma.subscribeUrl.includes('Action=Confirm'), true);

ok('sns.11 Notification que nao e alarme',
   cw([{ body: { Type: 'Notification', Message: 'oi' } }])[0].json._route, 'skip');
ok('sns.12 corpo nao-JSON', cw([{ body: 'nao sou json' }])[0].json._route, 'skip');

// Determinismo do hash: mesma entrada -> mesmo hash (reentrega do SNS)
ok('sns.13 hash determinista (reentrega e descartada)',
   cw([{ body: envelope }])[0].json.deliveryHash === snsObj.deliveryHash, true);

// Alarme fora da convencao de nome
const fora = cw([{ body: { Type: 'Notification', Message: JSON.stringify({
  AlarmName: 'alarme-solto', NewStateValue: 'ALARM',
  StateChangeTime: '2026-08-24T18:00:00.000+0000',
  Trigger: { MetricName: 'CPUUtilization' } }) } }])[0].json;
ok('fora.1 ainda ingere', fora._route, 'ingest');
ok('fora.2 recurso = nome inteiro', fora.resource, 'alarme-solto');
ok('fora.3 org fica nulo (nao inventa)', fora.org, null);
ok('fora.4 metrica vem do Trigger', fora.metric, 'CPUUtilization');

// ===================== Beanstalk =====================
console.log('\n--- Beanstalk ---');
const corpoEmail = [
  'Timestamp: Mon Aug 24 15:11:31 UTC 2026',
  'Message: Environment health has transitioned from Info to Degraded.',
  '  Application update in progress on 1 out of 4 instances.',
  '  Incorrect application version found on 1 instance.',
  'Environment: Api-Fechamento-env',
  'Application: Api-Fechamento-Validacao',
  'Environment URL: http://api-fechamento.sa-east-1.elasticbeanstalk.com',
  'NotificationProcessId: 1a2b3c4d-0000',
].join('\n');

const e1 = eb([{ textPlain: corpoEmail }])[0].json;
ok('eb.1 rota', e1._route, 'ingest');
ok('eb.2 hora do CORPO, nao do recebimento', e1.occurredAt, '2026-08-24T15:11:31.000Z');
ok('eb.3 fonte da hora', e1.timeSource, 'body_timestamp');
ok('eb.4 estado de origem', e1.fromState, 'Info');
ok('eb.5 estado de destino', e1.toState, 'Degraded');
ok('eb.6 environment', e1.environmentName, 'Api-Fechamento-env');
ok('eb.7 application', e1.applicationName, 'Api-Fechamento-Validacao');
ok('eb.8 dedup natural', e1.notificationProcessId, '1a2b3c4d-0000');
ok('eb.9 Message multilinha inteira',
   e1.message.includes('Incorrect application version found'), true);
ok('eb.10 "Environment URL" nao virou "Environment"', e1.environmentName, 'Api-Fechamento-env');

const e2 = eb([{ textHtml: '<html><body><p>Timestamp: Mon Aug 24 16:00:00 UTC 2026</p>' +
  '<p>Message: Environment health has transitioned from Degraded to Ok.</p>' +
  '<p>Environment: Api-Fechamento-env</p><p>Application: Api-Fechamento-Validacao</p></body></html>' }])[0].json;
ok('eb.11 so-HTML tambem funciona', e2.toState, 'Ok');
ok('eb.12 hora extraida do HTML', e2.occurredAt, '2026-08-24T16:00:00.000Z');

const e3 = eb([{ textPlain: 'Timestamp: Mon Aug 24 17:00:00 UTC 2026\n' +
  'Message: Environment health has transitioned from Ok to Severe.\n' +
  'Environment: Api-Fechamento-env' }])[0].json;
ok('eb.13 sem NotificationProcessId ainda ingere', e3._route, 'ingest');
ok('eb.14 hash de conteudo cobre a falta', typeof e3.deliveryHash, 'string');
ok('eb.15 application nulo, nao inventado', e3.applicationName, null);

ok('eb.16 e-mail sem transicao', eb([{ textPlain: 'Sua fatura chegou.' }])[0].json._route, 'skip');
ok('eb.17 e-mail vazio', eb([{}])[0].json._route, 'skip');

// ---- "No Data": a AWS escreve COM ESPACO ----
// Achado nos assuntos reais. Com [A-Za-z]+ no regex, estas quatro formas
// eram descartadas em silencio.
const nd1 = eb([{ textPlain: 'Timestamp: Mon Aug 24 18:00:00 UTC 2026\n' +
  'Message: Environment health has transitioned from Ok to No Data. None of the instances are sending data.\n' +
  'Environment: Api-Fechamento-env' }])[0].json;
ok('nd.1 "Ok to No Data" e reconhecido', nd1.toState, 'No Data');
ok('nd.2 rota de ingestao', nd1._route, 'ingest');

const nd2 = eb([{ textPlain: 'Timestamp: Mon Aug 24 18:05:00 UTC 2026\n' +
  'Message: Environment health has transitioned from No Data to Severe. 100.0 % of the requests are failing.\n' +
  'Environment: Api-Fechamento-env' }])[0].json;
ok('nd.3 "No Data to Severe" -- estado com espaco na ORIGEM', nd2.fromState, 'No Data');
ok('nd.4 destino correto', nd2.toState, 'Severe');

const nd3 = eb([{ textPlain: 'Timestamp: Mon Aug 24 18:10:00 UTC 2026\n' +
  'Message: Environment health has transitioned from Severe to No Data.\n' +
  'Environment: Api-Fechamento-env' }])[0].json;
ok('nd.5 "Severe to No Data" -- o caso que rebaixava o incidente', nd3.toState, 'No Data');

// ---- marco de deploy sem transicao de saude ----
const dep = eb([{ textPlain: 'Timestamp: Mon Aug 24 19:00:00 UTC 2026\n' +
  'Message: New application version was deployed to running EC2 instances.\n' +
  'Environment: Api-Fechamento-env\nApplication: Api-Fechamento-Validacao' }])[0].json;
ok('dep.1 nao e mais descartado', dep._route, 'ingest');
ok('dep.2 marcado como deploy', dep.eventType, 'deploy');
ok('dep.3 sem estado de destino', dep.toState, null);
ok('dep.4 saude normal continua marcada como health', e1.eventType, 'health');

// ruido de outra ferramenta no mesmo mailbox
ok('dep.5 alerta de teste do Grafana e descartado',
   eb([{ textPlain: 'Someone is testing the alert notification within Grafana.' }])[0].json._route, 'skip');

// ---- Beanstalk chegando por WEBHOOK, nao por e-mail ----
// E por aqui que os Severe vao entrar quando a KXC ligar o SNS. O mesmo
// corpo, outro involucro: o parser tem que reconhecer os dois.
const corpoSevere = [
  'Timestamp: Mon Aug 24 20:00:00 UTC 2026',
  'Message: Environment health has transitioned from Ok to Severe.',
  '  100.0 % of the requests are failing with HTTP 5xx.',
  'Environment: Api-Fechamento-env',
  'Application: Api-Fechamento-Producao',
  'NotificationProcessId: npid-sns-1',
].join('\n');

const snsEb = { Type: 'Notification', MessageId: 'm-eb-1',
                Message: corpoSevere, Timestamp: '2026-08-24T20:00:12.000Z' };

const w1 = eb([{ body: snsEb, headers: {} }])[0].json;
ok('sns.eb.1 reconhece Beanstalk vindo por SNS', w1._route, 'ingest');
ok('sns.eb.2 estado extraido',      w1.toState, 'Severe');
ok('sns.eb.3 transporte marcado',   w1.transport, 'sns');
ok('sns.eb.4 hora do corpo vence',  w1.occurredAt, '2026-08-24T20:00:00.000Z');
ok('sns.eb.5 ambiente lido',        w1.environmentName, 'Api-Fechamento-env');

// corpo como STRING (o SNS posta text/plain)
const w2 = eb([{ body: JSON.stringify(snsEb), headers: {} }])[0].json;
ok('sns.eb.6 corpo como string funciona igual', w2.deliveryHash, w1.deliveryHash);

// sem "Timestamp:" no corpo, cai no envelope do SNS -- nao no relogio local
const semTs = { Type: 'Notification',
  Message: 'Environment health has transitioned from Ok to Severe.\nEnvironment: Api-X-env',
  Timestamp: '2026-08-24T21:30:00.000Z' };
const w3 = eb([{ body: semTs }])[0].json;
ok('sns.eb.7 reserva e o envelope, nao now()', w3.occurredAt, '2026-08-24T21:30:00.000Z');
ok('sns.eb.8 fonte da hora rastreada',         w3.timeSource, 'sns_envelope');

// ---- os dois parsers sao mutuamente exclusivos ----
// O webhook alimenta ambos; cada um precisa recusar o que nao e seu, senao
// o mesmo evento entraria duas vezes.
ok('excl.1 CloudWatch recusa corpo do Beanstalk',
   cw([{ body: snsEb, headers: {} }])[0].json._route, 'skip');
ok('excl.2 Beanstalk recusa alarme do CloudWatch',
   eb([{ body: envelope, headers: {} }])[0].json._route, 'skip');
ok('excl.3 Beanstalk recusa confirmacao de assinatura',
   eb([{ body: { Type: 'SubscriptionConfirmation', SubscribeURL: 'https://x' } }])[0].json._route, 'skip');
ok('excl.4 CloudWatch continua aceitando o que e dele',
   cw([{ body: envelope, headers: {} }])[0].json._route, 'ingest');

// lote: o IMAP entrega varios de uma vez
const lote = eb([{ textPlain: corpoEmail }, { textPlain: 'lixo' }, { textPlain: corpoEmail }]);
ok('eb.18 lote preserva a ordem e o tamanho',
   lote.map(i => i.json._route), ['ingest', 'skip', 'ingest']);

console.log(falhas === 0 ? '\n=== PARSERS OK ===' : `\n=== ${falhas} FALHA(S) ===`);

// Emite o que sera mandado ao banco, para o teste ponta-a-ponta
fs.writeFileSync(process.argv[2] || 'payloads.json', JSON.stringify(
  [tgAlarm, tgOk, snsObj, e1, e2, e3].map(p => { const q = {...p}; delete q._route; return q; }), null, 2));

process.exit(falhas === 0 ? 0 : 1);

