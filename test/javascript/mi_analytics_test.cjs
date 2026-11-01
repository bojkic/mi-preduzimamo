const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname, '../../public/mi/mi-analytics.js'), 'utf8');
function browser({ path = '/', query = '', hash = '', referrer = '', cookie = '', meta = true, ga4Enabled = true } = {}) {
  const scripts = [], handlers = {}, writes = [];
  let reloads = 0, navigation;
  const location = { origin: 'https://mi.fondacijabijeljina.com', hostname: 'mi.fondacijabijeljina.com', pathname: path, search: query, hash,
    href: 'https://mi.fondacijabijeljina.com' + path + query + hash,
    reload() { reloads++; }, assign(url) { navigation = url; } };
  const config = { ga4_enabled: ga4Enabled, ga4_id: 'G-SEHNTQGXJ3', cookie_name: 'mi-consent-v2', google_ads_id: '', cloudflare_token: '5b41151a1ee54cafb2b46fcc02b29042', paths: ['/', '/ko-smo'] };
  const document = { referrer, head: { appendChild(el) { scripts.push(el); } },
    querySelector() { return meta ? { content: JSON.stringify(config) } : null; },
    createElement() { return { setAttribute(key, value) { this[key] = value; } }; },
    addEventListener(name, callback) { handlers[name] = callback; } };
  Object.defineProperty(document, 'cookie', { get() { return cookie; }, set(value) { writes.push(value); } });
  const window = { location, history: { pushState() {}, replaceState() {} }, addEventListener(name, fn) { handlers[name] = fn; } };
  const context = vm.createContext({ window, document, URL, URLSearchParams, Date });
  vm.runInContext(source, context);
  return { scripts, window, writes, runAgain() { vm.runInContext(source, context); },
    consent(state) { handlers.dataconsent?.({ detail: state }); }, reloads() { return reloads; }, navigation() { return navigation; } };
}
test('no requests before consent or after rejection', () => {
  const b = browser(); b.consent({ analytics: false }); assert.equal(b.scripts.length, 0);
});
test('acceptance loads both once, repeated events and loader do not duplicate', () => {
  const b = browser(); b.consent({ analytics: true }); b.consent({ analytics: true }); b.runAgain();
  assert.equal(b.scripts.length, 2);
  assert.equal(b.window.dataLayer.filter(x => x[0] === 'event').length, 1);
  assert.equal(JSON.parse(b.scripts[1]['data-cf-beacon']).spa, false);
});
test('restored consent works, malformed consent fails closed', () => {
  assert.equal(browser({ cookie: 'mi-consent-v2=%7B%22analytics%22%3Atrue%7D' }).scripts.length, 2);
  assert.equal(browser({ cookie: 'mi-consent-v2=invalid' }).scripts.length, 0);
});
test('sensitive routes and missing server config do not initialize', () => {
  for (const path of ['/registracija', '/admin', '/biceriseno/prijave/BR-1', '/users/sign_in', '/biceriseno', '/pozivnica', '/biceriseno/moj-nalog']) {
    const b = browser({ path }); b.consent({ analytics: true }); assert.equal(b.scripts.length, 0);
  }
  const b = browser({ meta: false }); b.consent({ analytics: true }); assert.equal(b.scripts.length, 0);
});
test('unsafe query values and fragments stop vendor initialization', () => {
  const b = browser({ query: '?email=private@example.test&utm_campaign=private', hash: '#secret', referrer: 'https://example.test/account/token?email=private' });
  b.consent({ analytics: true }); assert.equal(b.scripts.length, 0);
  assert.equal(b.window.dataLayer, undefined);
});
test('CF skips sensitive referring paths even without query', () => {
  const b = browser({ referrer: 'https://mi.fondacijabijeljina.com/biceriseno/prijave/BR-123' });
  b.consent({ analytics: true }); assert.equal(b.scripts.length, 1);
});
test('withdrawal disables GA, deletes its cookies, and reloads to unload beacon', () => {
  const b = browser({ cookie: '_ga=example; _ga_SEHNTQGXJ3=example; _ga_OTHERPROPERTY=preserve; _ga_extra=preserve' });
  b.consent({ analytics: true }); b.consent({ analytics: false });
  assert.equal(b.window['ga-disable-G-SEHNTQGXJ3'], true); assert.equal(b.reloads(), 1);
  assert.equal(b.writes.length, 4); assert(b.writes.every(x => x.includes('Max-Age=0')));
  assert(b.writes.every(x => !x.includes('Domain=.fondacijabijeljina.com')));
  assert(b.writes.every(x => /^_ga(?:_SEHNTQGXJ3)?=/.test(x)));
});
test('history navigation uses a new document after analytics starts', () => {
  const b = browser(); b.consent({ analytics: true }); b.window.history.pushState({}, '', '/registracija?token=secret');
  assert.equal(b.navigation(), 'https://mi.fondacijabijeljina.com/registracija?token=secret');
});

test('GA kill switch keeps Cloudflare working without Google requests', () => {
  const b = browser({ ga4Enabled: false }); b.consent({ analytics: true });
  assert.equal(b.scripts.length, 1); assert(b.scripts[0].src.includes('cloudflareinsights'));
  assert.equal(b.window.dataLayer, undefined);
});

test('server allowlist is limited to reviewed public information routes', () => {
  const configSource = fs.readFileSync(require('node:path').join(__dirname, '../../config/initializers/mi_web_analytics.rb'), 'utf8');
  const paths = configSource.match(/paths: %w\(([\s\S]*?)\)/)[1].trim().split(/\s+/);
  assert.deepEqual(paths, ['/', '/ko-smo', '/pitanja', '/trka', '/moderacija', '/neutralnost', '/processes', '/biceriseno/vodic', '/biceriseno/uticaj', '/biceriseno/zajednistvo', '/biceriseno/projekti', '/biceriseno/volontiranje', '/biceriseno/mjesne-zajednice']);
  assert(configSource.includes('ga4_enabled: true'));
  assert(configSource.includes('G-SEHNTQGXJ3'));
  assert(!configSource.includes('G-7N34SG6VMF'));
});
