// The gate in front of the tavern: a login page with an account and a
// password, and behind it every request passed on to the tavern, which listens
// inside the container only.
//
// The tavern's own login stays as it is: a link with a token that is printed
// when it starts, exchanged for a cookie. Nobody outside gets to either. The
// gate exchanges the link itself and adds the tavern's cookie to the requests
// of a browser that is logged in here; without a login here a request is
// passed on without any cookie, and one that tries the link is refused.
//
// So what the tavern serves without its cookie stays open, as it means it to
// be: character cards are drawn in frames that the browser keeps apart from
// the page, and it sends no cookie with what those fetch.
'use strict'

const http = require('node:http')
const crypto = require('node:crypto')
const { readFileSync } = require('node:fs')
const { setTimeout: delay } = require('node:timers/promises')
const { derive } = require('./login-common.cjs')

const BIND = process.env.TAVERN_GATE_BIND || '0.0.0.0'
const PORT = Number(process.env.TAVERN_GATE_PORT)
const INNER = Number(process.env.TAVERN_INNER_PORT)
const USER = process.env.DSH_LOGIN_USER || 'tavern'
const HASH = Buffer.from(process.env.DSH_LOGIN_HASH || '', 'hex')
const SECRET = Buffer.from(readFileSync(process.env.TAVERN_LOGIN_SECRET, 'utf8').trim(), 'base64')
// Written by the entrypoint whenever the tavern prints its link: "/?token=...".
const LINK = process.env.TAVERN_LOGIN_LINK
const PUBLIC = (() => { try { return new URL(process.env.DSH_PUBLIC_URL) } catch { return null } })()

const LOGIN_PATH = '/_login'
const COOKIE = 'tavern_login'
const DAY = 24 * 60 * 60 * 1000
// A login lasts this long from when it was last renewed, which using the
// tavern does once a day.
const LIFETIME = 30 * DAY
// Wrong passwords within the window before every attempt is turned away.
const WINDOW = 10 * 60 * 1000
const LIMIT = 10

// Changes with the account and with the password: a change of either ends
// every login there is.
const KEY = crypto.createHmac('sha256', SECRET).update(`session\0${USER}\0`).update(HASH).digest()

const HOP = new Set(['connection', 'expect', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade'])

function hostOf(req) {
  return String(req.headers.host || '').toLowerCase()
}

function cookiesOf(req) {
  const found = new Map()
  for (const part of String(req.headers.cookie || '').split(';')) {
    const at = part.indexOf('=')
    if (at > 0) found.set(part.slice(0, at).trim(), part.slice(at + 1).trim())
  }
  return found
}

// A browser that asks for a page to show, and not a page's own request.
function wantsPage(req) {
  return req.method === 'GET' && String(req.headers.accept || '').includes('text/html')
    && (req.headers['sec-fetch-dest'] ?? 'document') === 'document'
}

// ── the login here ──────────────────────────────────────────────────────────

function signature(body) {
  return crypto.createHmac('sha256', KEY).update(body).digest()
}

function issue(host) {
  const now = Date.now()
  const body = Buffer.from(JSON.stringify({ host, issued: now, expires: now + LIFETIME })).toString('base64url')
  return `${body}.${signature(body).toString('base64url')}`
}

// The login of a request, made out to the name the request is for.
function sessionOf(req) {
  const [body, signed, ...rest] = String(cookiesOf(req).get(COOKIE) || '').split('.')
  if (!body || !signed || rest.length > 0) return null
  const given = Buffer.from(signed, 'base64url')
  const expected = signature(body)
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return null
  let session
  try { session = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) } catch { return null }
  const now = Date.now()
  if (session.host !== hostOf(req) || !(session.issued <= now) || !(session.expires > now)) return null
  return session
}

// Over HTTPS only, where the page is reached over HTTPS.
function cookieFor(req, value) {
  let secure = false
  try { secure = PUBLIC !== null && PUBLIC.protocol === 'https:' && new URL(`https://${hostOf(req)}`).host === PUBLIC.host } catch {}
  return `${COOKIE}=${value}; Max-Age=${LIFETIME / 1000}; Path=/; HttpOnly; SameSite=Lax${secure ? '; Secure' : ''}`
}

const failures = []
let checking = 0
let checks = Promise.resolve()

function turnedAway() {
  const now = Date.now()
  while (failures.length > 0 && now - failures[0] > WINDOW) failures.shift()
  return failures.length >= LIMIT || checking >= 3
}

function digest(text) {
  return crypto.createHash('sha256').update(text).digest()
}

// One after the other: each takes a good deal of memory for a moment.
function check(username, password) {
  const result = checks.then(async () => {
    const derived = await derive(password, SECRET)
    const account = crypto.timingSafeEqual(digest(username), digest(USER))
    return derived.length === HASH.length && crypto.timingSafeEqual(derived, HASH) && account
  })
  checks = result.catch(() => {})
  return result
}

function loginPage(message = '') {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>DSH Tavern 登录</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 16px/1.5 system-ui, sans-serif; background: #f4f1ec; color: #2b2622; }
  form { width: min(22rem, calc(100vw - 3rem)); padding: 2rem; border-radius: 1rem; background: #fffdf9; box-shadow: 0 0.5rem 2rem rgb(0 0 0 / 12%); }
  h1 { margin: 0 0 1.5rem; font-size: 1.4rem; }
  label { display: block; margin: 1rem 0 0.35rem; font-size: 0.9rem; }
  input { box-sizing: border-box; width: 100%; padding: 0.6rem 0.75rem; border: 1px solid #cfc7bc; border-radius: 0.5rem; font: inherit; background: inherit; color: inherit; }
  button { width: 100%; margin-top: 1.5rem; padding: 0.7rem; border: 0; border-radius: 0.5rem; font: inherit; color: #fff; background: #c2714f; cursor: pointer; }
  p { margin: 1rem 0 0; color: #b3261e; font-size: 0.9rem; }
  @media (prefers-color-scheme: dark) { body { background: #1d1a17; color: #ece6de; } form { background: #2a2622; } input { border-color: #55504a; } }
</style>
</head>
<body>
<form method="post" action="${LOGIN_PATH}">
  <h1>DSH Tavern</h1>
  <label for="username">账号</label>
  <input id="username" name="username" autocomplete="username" autocapitalize="none" required autofocus>
  <label for="password">密码</label>
  <input id="password" name="password" type="password" autocomplete="current-password" required>
  <button type="submit">登录</button>
  ${message ? `<p role="alert">${message}</p>` : ''}
</form>
</body>
</html>
`
}

function page(res, status, body, headers = {}) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    ...headers,
  })
  res.end(body)
}

function plain(res, status, text, headers = {}) {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', ...headers })
  res.end(`${text}\n`)
}

function toLogin(res) {
  res.writeHead(302, { location: LOGIN_PATH, 'cache-control': 'no-store' })
  res.end()
}

function bodyOf(req, limit) {
  return new Promise((resolve, reject) => {
    const parts = []
    let size = 0
    req.on('data', (part) => {
      size += part.length
      if (size > limit) {
        reject(new Error('too large'))
        req.destroy()
        return
      }
      parts.push(part)
    })
    req.on('end', () => resolve(Buffer.concat(parts).toString('utf8')))
    req.on('error', reject)
  })
}

async function login(req, res) {
  if (req.method === 'GET' || req.method === 'HEAD') {
    if (sessionOf(req)) {
      res.writeHead(302, { location: '/', 'cache-control': 'no-store' })
      res.end()
      return
    }
    page(res, 200, loginPage())
    return
  }
  if (req.method !== 'POST') {
    plain(res, 405, '不支持的请求。', { allow: 'GET, HEAD, POST' })
    return
  }
  if (turnedAway()) {
    page(res, 429, loginPage('尝试的次数太多了，请过几分钟再试。'), { 'retry-after': '60' })
    return
  }
  let form
  try { form = new URLSearchParams(await bodyOf(req, 8192)) } catch { return }
  checking += 1
  let passed = false
  try { passed = await check(form.get('username') || '', form.get('password') || '') } finally { checking -= 1 }
  if (!passed) {
    failures.push(Date.now())
    const from = String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').replace(/[^0-9a-fA-F:., ]/g, '').slice(0, 80)
    console.log(`登录失败（${WINDOW / 60000} 分钟内第 ${failures.length} 次），来自 ${from || '未知地址'}。`)
    await delay(400)
    page(res, 401, loginPage('账号或密码不对。'))
    return
  }
  res.writeHead(303, { location: '/', 'set-cookie': cookieFor(req, issue(hostOf(req))), 'cache-control': 'no-store' })
  res.end()
}

// ── the tavern's own login, kept in here ────────────────────────────────────

const kept = new Map()
const asking = new Map()

function link() {
  try {
    const text = readFileSync(LINK, 'utf8').trim()
    return text.startsWith('/?token=') ? text : ''
  } catch {
    return ''
  }
}

// Exchanges the tavern's link for its cookie, which it makes out to a name.
function exchange(host, path) {
  return new Promise((resolve) => {
    const asked = http.get({ host: '127.0.0.1', port: INNER, path, headers: { host } }, (answer) => {
      answer.resume()
      const cookie = (answer.headers['set-cookie'] || []).map(value => value.split(';')[0].trim()).find(value => value.startsWith('dsh-auth-'))
      resolve(cookie || '')
    })
    asked.on('error', () => resolve(''))
  })
}

async function ask(host) {
  // A while, for a tavern that is starting or has just started with a new link.
  for (let attempt = 0; attempt < 10; attempt++) {
    if (attempt > 0) await delay(1000)
    const path = link()
    const cookie = path ? await exchange(host, path) : ''
    if (!cookie) continue
    kept.set(host, { cookie, until: Date.now() + 20 * DAY })
    if (kept.size > 64) kept.delete(kept.keys().next().value)
    return cookie
  }
  throw new Error('the tavern does not answer')
}

function tavernCookie(host) {
  const have = kept.get(host)
  if (have && have.until > Date.now()) return Promise.resolve(have.cookie)
  if (!asking.has(host)) asking.set(host, ask(host).finally(() => asking.delete(host)))
  return asking.get(host)
}

// ── passing requests on ─────────────────────────────────────────────────────

// The headers of a request for the tavern, with the cookies it is to see.
function passedOn(req, cookie) {
  const headers = {}
  for (const [name, value] of Object.entries(req.headers)) {
    if (!HOP.has(name) && name !== 'cookie') headers[name] = value
  }
  if (cookie) headers.cookie = cookie
  return headers
}

// The cookies of a browser that is logged in here, as the tavern is to see
// them: without the one of the gate, and with the tavern's own.
function withTavernCookie(req, cookie) {
  const cookies = []
  for (const [name, value] of cookiesOf(req)) {
    if (name !== COOKIE && !name.startsWith('dsh-auth-')) cookies.push(`${name}=${value}`)
  }
  cookies.push(cookie)
  return cookies.join('; ')
}

function send(req, res, cookie, { answered, failed }) {
  const passed = http.request({ host: '127.0.0.1', port: INNER, method: req.method, path: req.url, headers: passedOn(req, cookie) })
  passed.on('response', answered)
  passed.on('error', failed)
  res.on('close', () => passed.destroy())
  if (req.method === 'GET' || req.method === 'HEAD') passed.end()
  else req.pipe(passed)
}

// The tavern's answer for the browser. Its own cookie never leaves.
function relay(answer, res, cookies = []) {
  const headers = []
  for (let at = 0; at < answer.rawHeaders.length; at += 2) {
    const name = answer.rawHeaders[at]
    const value = answer.rawHeaders[at + 1]
    const lower = name.toLowerCase()
    if (HOP.has(lower) || (lower === 'set-cookie' && value.trimStart().startsWith('dsh-auth-'))) continue
    headers.push(name, value)
  }
  for (const cookie of cookies) headers.push('Set-Cookie', cookie)
  res.writeHead(answer.statusCode, answer.statusMessage, headers)
  res.flushHeaders()
  answer.pipe(res)
}

function notUp(req, res) {
  if (res.headersSent) {
    res.destroy()
    return
  }
  if (wantsPage(req)) {
    page(res, 503, '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta http-equiv="refresh" content="3"><title>DSH Tavern</title><body style="font: 16px system-ui, sans-serif; padding: 2rem">酒馆正在启动或更新，请稍候，页面会自己刷新。</body></html>\n', { 'retry-after': '3' })
    return
  }
  plain(res, 503, '酒馆正在启动或更新。', { 'retry-after': '3' })
}

async function loggedIn(req, res, session) {
  const host = hostOf(req)
  let cookie
  try { cookie = await tavernCookie(host) } catch { return notUp(req, res) }
  // Using the tavern keeps the login here from running out.
  const renewed = Date.now() - session.issued > DAY ? [cookieFor(req, issue(host))] : []
  const attempt = (again) => send(req, res, withTavernCookie(req, cookie), {
    answered(answer) {
      if (answer.statusCode === 401) {
        // The tavern no longer takes the cookie kept for it.
        kept.delete(host)
        if (again && (req.method === 'GET' || req.method === 'HEAD')) {
          answer.resume()
          tavernCookie(host).then((fresh) => { cookie = fresh; attempt(false) }, () => notUp(req, res))
          return
        }
      }
      relay(answer, res, renewed)
    },
    failed: () => notUp(req, res),
  })
  attempt(true)
}

function notLoggedIn(req, res, url) {
  const refuse = () => (wantsPage(req) ? toLogin(res) : plain(res, 401, '请先登录。'))
  // Reading is all that the tavern serves without its cookie, and its link is
  // not for trying from outside.
  if ((req.method !== 'GET' && req.method !== 'HEAD') || url.pathname === '/connect' || url.searchParams.has('token')) {
    refuse()
    return
  }
  send(req, res, '', {
    answered(answer) {
      if (answer.statusCode === 401 && wantsPage(req)) {
        answer.resume()
        toLogin(res)
        return
      }
      relay(answer, res)
    },
    failed: () => (wantsPage(req) ? toLogin(res) : notUp(req, res)),
  })
}

async function handle(req, res) {
  if (!req.headers.host) {
    plain(res, 400, '请求里没有 Host。')
    return
  }
  // Read the address the way the tavern does.
  const url = new URL(req.url || '/', 'http://tavern.invalid')
  if (url.pathname === LOGIN_PATH) {
    await login(req, res)
    return
  }
  const session = sessionOf(req)
  if (session) await loggedIn(req, res, session)
  else notLoggedIn(req, res, url)
}

// A WebSocket: opened by the page of a browser that is logged in here.
function upgrade(req, socket, head) {
  const refuse = (status, text) => socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
  socket.on('error', () => socket.destroy())
  if (!req.headers.host || !sessionOf(req)) {
    refuse(401, 'Unauthorized')
    return
  }
  tavernCookie(hostOf(req)).then((cookie) => {
    const headers = passedOn(req, withTavernCookie(req, cookie))
    headers.connection = 'Upgrade'
    headers.upgrade = req.headers.upgrade
    const passed = http.request({ host: '127.0.0.1', port: INNER, method: req.method, path: req.url, headers })
    passed.on('upgrade', (answer, tavern, first) => {
      const lines = [`HTTP/1.1 ${answer.statusCode} ${answer.statusMessage}`]
      for (let at = 0; at < answer.rawHeaders.length; at += 2) lines.push(`${answer.rawHeaders[at]}: ${answer.rawHeaders[at + 1]}`)
      socket.write(`${lines.join('\r\n')}\r\n\r\n`)
      if (first.length > 0) socket.write(first)
      if (head.length > 0) tavern.write(head)
      const close = () => { socket.destroy(); tavern.destroy() }
      tavern.on('error', close)
      tavern.on('close', close)
      socket.on('close', close)
      socket.setNoDelay(true)
      tavern.setNoDelay(true)
      tavern.pipe(socket)
      socket.pipe(tavern)
    })
    passed.on('response', (answer) => {
      answer.resume()
      refuse(answer.statusCode, answer.statusMessage)
    })
    passed.on('error', () => refuse(502, 'Bad Gateway'))
    passed.end()
  }, () => refuse(503, 'Service Unavailable'))
}

if (HASH.length === 0 || SECRET.length < 32 || !LINK || !Number.isInteger(PORT) || !Number.isInteger(INNER)) {
  console.error('gate: not told the password, the secret or the ports')
  process.exit(1)
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((error) => {
    console.error('gate:', error)
    if (res.headersSent) res.destroy()
    else plain(res, 500, '出错了。')
  })
})
server.on('upgrade', upgrade)
// Uploads and answers that are streamed take as long as they take.
server.requestTimeout = 0
server.timeout = 0
server.listen(PORT, BIND)
process.on('SIGTERM', () => process.exit(0))
