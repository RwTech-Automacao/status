import fs from 'node:fs';
const dir = import.meta.dirname + '/';

const codigoCw = fs.readFileSync(dir + 'n8n-code-node.js', 'utf8');
const codigoEb = fs.readFileSync(dir + 'n8n-code-beanstalk.js', 'utf8');

const cond = (valor, id) => ({
  options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
  conditions: [{
    id,
    leftValue: '={{ $json._route }}',
    rightValue: valor,
    operator: { type: 'string', operation: 'equals' },
  }],
  combinator: 'and',
});

const no = (name, type, typeVersion, position, parameters, extra = {}) =>
  Object.assign({ parameters, id: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
                  name, type, typeVersion, position }, extra);

const workflow = {
  name: 'Status — Ingestao de disponibilidade',
  nodes: [
    // ---------------- gatilhos ----------------
    no('Telegram Trigger', 'n8n-nodes-base.telegramTrigger', 1.1, [-620, -160],
       { updates: ['message'], additionalFields: {} }),

    // Caminho `sla/aws` porque e onde o Grafana da KXC ja esta postando --
    // mudar do lado deles seria atrito a toa. O no aceita os tres formatos:
    // Grafana (legado e unificado), SNS/CloudWatch e aviso do Beanstalk.
    no('Webhook alarmes', 'n8n-nodes-base.webhook', 2, [-620, 20],
       { httpMethod: 'POST', path: 'sla/aws',
         responseMode: 'onReceived', options: {} },
       { webhookId: 'status-alarmes' }),

    no('E-mail IMAP', 'n8n-nodes-base.emailReadImap', 2, [-620, 240],
       { mailbox: 'INBOX', postProcessAction: 'read', format: 'simple', options: {} }),

    // ---------------- normalizacao ----------------
    no('Normaliza CloudWatch', 'n8n-nodes-base.code', 2, [-340, -70],
       { mode: 'runOnceForAllItems', jsCode: codigoCw }),

    no('Normaliza Beanstalk', 'n8n-nodes-base.code', 2, [-340, 240],
       { mode: 'runOnceForAllItems', jsCode: codigoEb }),

    // ---------------- roteamento ----------------
    no('Switch', 'n8n-nodes-base.switch', 3.2, [-60, 60], {
      rules: {
        values: [
          { conditions: cond('ingest', 'r-ingest'),           renameOutput: true, outputKey: 'ingest' },
          { conditions: cond('confirm_sns', 'r-confirm'),     renameOutput: true, outputKey: 'confirm_sns' },
          { conditions: cond('skip', 'r-skip'),               renameOutput: true, outputKey: 'skip' },
        ],
      },
      options: {},
    }),

    // ---------------- destinos ----------------
    // UM parametro so, jsonb. O array em queryReplacement e proposital:
    // o campo aceita "lista separada por virgula", e um JSON tem virgulas --
    // sem os colchetes o n8n picota o payload e quebra em silencio.
    no('Postgres: ingest_health', 'n8n-nodes-base.postgres', 2.4, [220, -140], {
      operation: 'executeQuery',
      query: 'select * from ingest_health($1::jsonb)',
      options: { queryReplacement: '={{ [JSON.stringify($json)] }}' },
    }),

    no('Confirma assinatura SNS', 'n8n-nodes-base.httpRequest', 4.2, [220, 60],
       { url: '={{ $json.subscribeUrl }}', options: {} }),

    no('Nao e alarme', 'n8n-nodes-base.noOp', 1, [220, 260], {}),
  ],

  connections: {
    'Telegram Trigger': { main: [[{ node: 'Normaliza CloudWatch', type: 'main', index: 0 }]] },

    // O webhook alimenta os DOIS normalizadores porque não se sabe de
    // antemão o que vem nele: alarme do CloudWatch ou aviso de saúde do
    // Beanstalk (é por onde chegam os Severe). Cada parser descarta o que
    // não é seu -- eles são mutuamente exclusivos: um exige AlarmName no
    // Message, o outro exige "health has transitioned". O item rejeitado
    // sai como _route:'skip' e morre no NoOp.
    //
    // Se algum dia os dois reivindicassem o mesmo evento, o deliveryHash
    // em webhook_deliveries impediria a gravação em dobro.
    'Webhook alarmes': { main: [[
      { node: 'Normaliza CloudWatch', type: 'main', index: 0 },
      { node: 'Normaliza Beanstalk',  type: 'main', index: 0 },
    ]] },

    'E-mail IMAP': { main: [[{ node: 'Normaliza Beanstalk', type: 'main', index: 0 }]] },
    'Normaliza CloudWatch':  { main: [[{ node: 'Switch', type: 'main', index: 0 }]] },
    'Normaliza Beanstalk':   { main: [[{ node: 'Switch', type: 'main', index: 0 }]] },
    'Switch': {
      main: [
        [{ node: 'Postgres: ingest_health',   type: 'main', index: 0 }],
        [{ node: 'Confirma assinatura SNS',   type: 'main', index: 0 }],
        [{ node: 'Nao e alarme',              type: 'main', index: 0 }],
      ],
    },
  },

  settings: { executionOrder: 'v1' },
  pinData: {},
};

fs.writeFileSync(dir + 'n8n-workflow.json', JSON.stringify(workflow, null, 2));

/* =========================================================================
 * Workflow 2 — API publica que alimenta o status.html
 *
 * Separado do de ingestao de proposito: os dois tem ciclo de vida
 * diferente. Derrubar a API para mexer nela nao pode parar a coleta de
 * alarmes -- historico perdido nao se recupera.
 *
 * A seguranca NAO esta aqui: esta na query. O no chama status_json(), que
 * so le de public_components (published = true E environment = 'producao')
 * e nunca devolve incidents.detail -- onde mora a mensagem crua da AWS,
 * com nome de pessoa, versao interna e zona de disponibilidade.
 * Ver o cabecalho de api.sql.
 * ====================================================================== */
const workflowApi = {
  name: 'Status — API publica',
  nodes: [
    no('Webhook status', 'n8n-nodes-base.webhook', 2, [-400, 0],
       { httpMethod: 'GET', path: 'status',
         // responseNode: quem responde e o ultimo no, nao o webhook
         responseMode: 'responseNode', options: {} },
       { webhookId: 'status-publico' }),

    // Uma ida ao banco por requisicao. Medido: ~85 ms com 8 servicos e
    // 720 incidentes, payload de 73 KB.
    no('Postgres: status_json', 'n8n-nodes-base.postgres', 2.4, [-120, 0],
       { operation: 'executeQuery',
         query: 'select status_json() as payload',
         options: {} }),

    // ---- tela operacional (interna) ----
    // Endpoint separado porque a exposição é outra: picos_json_req devolve
    // todos os ambientes e a mensagem crua da AWS. Depende do login no
    // middleware do Vercel -- nunca deve ser aberto junto com /status.
    no('Webhook picos', 'n8n-nodes-base.webhook', 2, [-400, 200],
       { httpMethod: 'GET', path: 'picos',
         responseMode: 'responseNode', options: {} },
       { webhookId: 'status-picos' }),

    // A querystring inteira vai como UM parâmetro jsonb, igual à ingestão.
    // São três valores possíveis (de, ate, janela) e placeholder posicional
    // é onde o n8n quebra em silêncio.
    no('Postgres: picos_json', 'n8n-nodes-base.postgres', 2.4, [-120, 200],
       { operation: 'executeQuery',
         query: 'select picos_json_req($1::jsonb) as payload',
         options: { queryReplacement: '={{ [JSON.stringify($json.query || {})] }}' } }),

    no('Responde picos', 'n8n-nodes-base.respondToWebhook', 1.1, [160, 200], {
      respondWith: 'json',
      responseBody: '={{ $json.payload }}',
      options: { responseHeaders: { entries: [
        { name: 'Access-Control-Allow-Origin', value: '*' },
        // Dado interno e parametrizado: não pode ficar em cache compartilhado
        { name: 'Cache-Control', value: 'no-store' },
        { name: 'Content-Type', value: 'application/json; charset=utf-8' },
      ] } },
    }),

    no('Responde JSON', 'n8n-nodes-base.respondToWebhook', 1.1, [160, 0], {
      respondWith: 'json',
      responseBody: '={{ $json.payload }}',
      options: { responseHeaders: { entries: [
        // a pagina roda em outro dominio; sem isto o navegador bloqueia
        { name: 'Access-Control-Allow-Origin', value: '*' },
        // 60s de cache: deixa o Neon hibernar em vez de acordar a cada visita
        { name: 'Cache-Control', value: 'public, max-age=60' },
        { name: 'Content-Type', value: 'application/json; charset=utf-8' },
      ] } },
    }),
  ],
  connections: {
    'Webhook status':        { main: [[{ node: 'Postgres: status_json', type: 'main', index: 0 }]] },
    'Postgres: status_json': { main: [[{ node: 'Responde JSON',         type: 'main', index: 0 }]] },
    'Webhook picos':         { main: [[{ node: 'Postgres: picos_json',  type: 'main', index: 0 }]] },
    'Postgres: picos_json':  { main: [[{ node: 'Responde picos',        type: 'main', index: 0 }]] },
  },
  settings: { executionOrder: 'v1' },
  pinData: {},
};

fs.writeFileSync(dir + 'n8n-workflow-api.json', JSON.stringify(workflowApi, null, 2));

// sanidade: re-le, confere que os parsers voltam identicos e que os alvos existem
const lido = JSON.parse(fs.readFileSync(dir + 'n8n-workflow.json', 'utf8'));
const porNome = Object.fromEntries(lido.nodes.map(n => [n.name, n]));

const checa = (caso, cond) => console.log((cond ? 'ok  ' : 'FALHOU ') + caso);
checa('JSON re-parseia', true);
checa('parser CloudWatch intacto apos round-trip',
      porNome['Normaliza CloudWatch'].parameters.jsCode === codigoCw);
checa('parser Beanstalk intacto apos round-trip',
      porNome['Normaliza Beanstalk'].parameters.jsCode === codigoEb);
checa('todo alvo de conexao existe',
      Object.values(lido.connections).flatMap(c => c.main.flat()).every(t => porNome[t.node]));
checa('Switch tem 3 saidas para 3 ramos',
      porNome['Switch'].parameters.rules.values.length === lido.connections['Switch'].main.length);
checa('queryReplacement usa a forma de array',
      porNome['Postgres: ingest_health'].parameters.options.queryReplacement.includes('[JSON.stringify'));
checa('todos os nos tem nome unico',
      new Set(lido.nodes.map(n => n.name)).size === lido.nodes.length);
console.log(`\n${lido.nodes.length} nos, ${Object.keys(lido.connections).length} origens de conexao`);

// ---- workflow da API ----
const api = JSON.parse(fs.readFileSync(dir + 'n8n-workflow-api.json', 'utf8'));
const apiPorNome = Object.fromEntries(api.nodes.map(n => [n.name, n]));

console.log('\n[API publica]');
checa('JSON re-parseia', true);
checa('webhook responde pelo no final (responseNode)',
      apiPorNome['Webhook status'].parameters.responseMode === 'responseNode');
checa('query e so status_json -- nenhuma tabela crua',
      apiPorNome['Postgres: status_json'].parameters.query === 'select status_json() as payload');
checa('query NAO cita incidents, health_events nem detail',
      !/incidents|health_events|detail|components/i.test(apiPorNome['Postgres: status_json'].parameters.query));
checa('CORS liberado para o navegador',
      apiPorNome['Responde JSON'].parameters.options.responseHeaders.entries
        .some(h => h.name === 'Access-Control-Allow-Origin'));
checa('Cache-Control presente',
      apiPorNome['Responde JSON'].parameters.options.responseHeaders.entries
        .some(h => h.name === 'Cache-Control'));
checa('todo alvo de conexao existe',
      Object.values(api.connections).flatMap(c => c.main.flat()).every(t => apiPorNome[t.node]));
console.log(`${api.nodes.length} nos`);

