// Goes to the tavern the way a person does behind the reverse proxy of
// openresty.conf: with a browser that knows the account and the password and
// nothing else. Checks that it arrives in the tavern, that the page keeps its
// connection, and what a frame that is kept apart from the page can fetch.
//
//   node proxy-check.cjs <site> <user> <password> <directory>
//
// The site's name is taken to be this machine. Needs playwright-core on
// NODE_PATH and Chrome on the machine.
const { chromium } = require('playwright-core')
const { mkdirSync, writeFileSync } = require('node:fs')
const path = require('node:path')

const failures = []
function check(what, passed, seen) {
  console.log(`${passed ? 'ok    ' : 'FAILED'}  ${what}: ${seen}`)
  if (!passed) failures.push(what)
}

async function main() {
  const [site, username, password, directory] = process.argv.slice(2)
  if (!site || !username || !password || !directory) throw new Error('usage: proxy-check.cjs <site> <user> <password> <directory>')
  mkdirSync(directory, { recursive: true })
  const { hostname } = new URL(site)
  const browser = await chromium.launch({ channel: 'chrome', args: [`--host-resolver-rules=MAP ${hostname} 127.0.0.1`] })
  try {
    const context = await browser.newContext({
      ignoreHTTPSErrors: true,
      httpCredentials: { username, password },
      viewport: { width: 1440, height: 900 },
      locale: 'zh-CN',
    })
    const page = await context.newPage()
    const sockets = []
    page.on('websocket', (socket) => {
      const entry = { path: new URL(socket.url()).pathname, received: 0 }
      sockets.push(entry)
      socket.on('framereceived', () => { entry.received += 1 })
    })
    const visited = []
    page.on('response', (response) => {
      const request = response.request()
      if (!request.isNavigationRequest() || request.frame() !== page.mainFrame()) return
      const url = new URL(response.url())
      visited.push(`${response.status()} ${url.pathname}${url.search ? '?...' : ''}`)
    })

    await page.goto(`${site}/`, { waitUntil: 'load' })
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(5000)

    const address = new URL(page.url())
    console.log(`        the way there: ${visited.join('  ->  ')}`)
    check('arrives at the page without the login link in the address', address.pathname === '/' && address.search === '', address.pathname + address.search.replace(/=.*/, '=...'))
    const title = await page.title()
    check('the page is the tavern', /tavern/i.test(title), title)
    const live = sockets.filter(socket => socket.received > 0)
    check('the page keeps a connection open through the proxy', live.length > 0, JSON.stringify(sockets))

    // A frame the browser keeps apart from the page, as the ones that cards
    // are drawn in: it has no origin of its own, and what it fetches carries
    // neither the password nor a cookie.
    await page.evaluate(() => {
      const frame = document.createElement('iframe')
      frame.name = 'smoke-apart'
      frame.setAttribute('sandbox', 'allow-scripts')
      frame.srcdoc = '<!doctype html><title>apart</title>'
      document.body.appendChild(frame)
    })
    const frame = await page.waitForSelector('iframe[name="smoke-apart"]').then(element => element.contentFrame())
    const fetched = url => frame.evaluate(target => fetch(target).then(response => String(response.status), () => 'no answer'), url)
    const origin = await frame.evaluate(() => self.origin)
    check('the frame is kept apart from the page', origin === 'null', origin)
    // Served by the tavern without a login; it answers 403 to a made-up key.
    const open = await fetched(`${site}/api/dsh-tavern/session-resource?cap=smoke`)
    check('the frame reaches what the tavern serves without a login', open === '403', open)
    // Needs the login; the proxy asks for the password, which the frame does not have.
    const closed = await fetched(`${site}/api/dsh-tavern/card-image?smoke=1`)
    check('the frame does not reach what needs the login', closed === 'no answer', closed)

    await page.screenshot({ path: path.join(directory, 'through-proxy.png') })
    writeFileSync(path.join(directory, 'through-proxy.txt'), `${title}\n${address.origin}${address.pathname}\n\n${await page.evaluate(() => document.body.innerText)}\n`)
  } finally {
    await browser.close()
  }
  if (failures.length > 0) process.exit(1)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
