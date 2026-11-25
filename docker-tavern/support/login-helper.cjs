// For a reverse proxy that checks an account and a password itself: sends a
// browser that the proxy has let in on to the tavern's own login link, so that
// nobody has to copy that link out of the log.
//
// The tavern's own login stays as it is. The proxy asks here only once the
// tavern has answered a browser, whose password it has checked, that it is not
// logged in; the answer is a redirect to the link the service printed last.
//
// Whoever reaches this port is let into the tavern. It listens only when
// DSH_TAVERN_LOGIN_PORT is set, and that port is for the proxy alone.
const http = require('node:http')
const { readFileSync } = require('node:fs')

// Written by the entrypoint whenever the service prints a link: "/?token=...".
const file = '/run/dsh-tavern-docker/login'
const port = Number(process.env.DSH_TAVERN_LOGIN_PORT)
const host = process.env.DSH_TAVERN_BIND

function answer(res, status, headers, text) {
  res.writeHead(status, { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8', ...headers })
  res.end(`${text}\n`)
}

http.createServer((req, res) => {
  let link = ''
  try { link = readFileSync(file, 'utf8').trim() } catch {}
  if (!link.startsWith('/?token=')) {
    answer(res, 503, { 'retry-after': '5' }, '酒馆正在启动，请稍后刷新。')
    return
  }
  // The request the tavern refused is passed on as it came. One that carries
  // the current link already was refused with it: sending it there again
  // would go round in circles.
  const tried = new URL(req.url || '/', 'http://tavern.invalid').searchParams.get('token')
  if (tried !== null && `/?token=${tried}` === link) {
    answer(res, 401, {}, '酒馆没有接受登录，请稍后再试。')
    return
  }
  answer(res, 302, { location: link, 'referrer-policy': 'no-referrer' }, '正在进入酒馆……')
}).listen(port, host)
