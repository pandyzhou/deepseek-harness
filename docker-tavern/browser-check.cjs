// Goes to the tavern the way a person does: with a browser, through the
// reverse proxy, knowing the account and the password and nothing else. Checks
// that the login page comes up and lets in, that the page keeps its
// connections, and what a frame that is kept apart from the page can fetch.
// Leaves pictures of the login page and of the first screen.
//
//   node browser-check.cjs <site> <account> <password> <directory>
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
  const [site, account, password, directory] = process.argv.slice(2)
  if (!site || !account || !password || !directory) throw new Error('usage: browser-check.cjs <site> <account> <password> <directory>')
  mkdirSync(directory, { recursive: true })
  const { hostname } = new URL(site)
  const browser = await chromium.launch({ channel: 'chrome', args: [`--host-resolver-rules=MAP ${hostname} 127.0.0.1`] })
  try {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 900 }, locale: 'zh-CN' })
    const page = await context.newPage()
    const sockets = []
    page.on('websocket', (socket) => {
      const entry = { path: new URL(socket.url()).pathname, received: 0 }
      sockets.push(entry)
      socket.on('framereceived', () => { entry.received += 1 })
    })

    await page.goto(`${site}/`, { waitUntil: 'load' })
    check('a browser that is not logged in is shown the login page', new URL(page.url()).pathname === '/_login', new URL(page.url()).pathname)
    await page.screenshot({ path: path.join(directory, 'login-page.png') })

    await page.fill('input[name="username"]', account)
    await page.fill('input[name="password"]', password)
    await Promise.all([
      page.waitForURL(url => url.pathname === '/', { timeout: 60000 }),
      page.click('button[type="submit"]'),
    ])
    // The page builds itself after it has loaded.
    await page.waitForFunction(() => document.body !== null && document.body.innerText.trim().length > 20, null, { timeout: 60000 })
    await page.waitForTimeout(2000)

    const address = new URL(page.url())
    check('after the login it is at the page, with nothing in the address', address.pathname === '/' && address.search === '', address.pathname + address.search)
    const title = await page.title()
    check('the page is the tavern', /tavern/i.test(title) && !/登录/.test(title), title)
    const cookies = await context.cookies()
    const login = cookies.find(cookie => cookie.name === 'tavern_login')
    check('the login is kept in a cookie that scripts cannot read, sent over HTTPS only', Boolean(login && login.httpOnly && login.secure && login.sameSite === 'Lax'),
      JSON.stringify(login && { httpOnly: login.httpOnly, secure: login.secure, sameSite: login.sameSite, days: Math.round((login.expires - Date.now() / 1000) / 86400) }))
    check('the tavern\'s own cookie does not reach the browser', !cookies.some(cookie => cookie.name.startsWith('dsh-auth-')), cookies.map(cookie => cookie.name.slice(0, 16)).join(', '))

    for (let waited = 0; waited < 20 && !sockets.some(socket => socket.received > 0); waited++) await page.waitForTimeout(1000)
    check('the page keeps connections open through the proxy and the gate', sockets.some(socket => socket.received > 0), JSON.stringify(sockets))

    // A frame the browser keeps apart from the page, as the ones that cards
    // are drawn in: it has no origin of its own, and what it fetches carries
    // no cookie.
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
    // Needs the login, which the frame does not have.
    const closed = await fetched(`${site}/api/dsh-tavern/card-image?smoke=1`)
    check('the frame does not reach what needs the login', closed === 'no answer', closed)

    await page.screenshot({ path: path.join(directory, 'first-screen.png') })
    const text = await page.evaluate(() => document.body.innerText)
    writeFileSync(path.join(directory, 'first-screen.txt'), `${title}\n${address.origin}${address.pathname}\n\n${text}\n`)
    // What the page says when it finds no Documents directory to start in.
    check('the page starts without a complaint about its workspace', !text.includes('无法创建默认工作区'), text.includes('无法创建默认工作区') ? 'it complains' : 'no complaint')
  } finally {
    await browser.close()
  }
  if (failures.length > 0) process.exit(1)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
