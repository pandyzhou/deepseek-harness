// Opens the page the way a person does who follows the login link for the
// first time, and keeps a picture of what is on the screen then, together with
// its text.
//
//   node first-screen.cjs <login link> <directory>
//
// Needs playwright-core on NODE_PATH and Chrome on the machine.
const { chromium } = require('playwright-core')
const { mkdirSync, writeFileSync } = require('node:fs')
const path = require('node:path')

async function main() {
  const [link, directory] = process.argv.slice(2)
  if (!link || !directory) throw new Error('usage: first-screen.cjs <login link> <directory>')
  mkdirSync(directory, { recursive: true })
  const browser = await chromium.launch({ channel: 'chrome' })
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, locale: 'zh-CN' })
    await page.goto(link, { waitUntil: 'load' })
    // The page builds itself after it has loaded, and goes quiet once it has.
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {})
    await page.waitForTimeout(5000)
    await page.screenshot({ path: path.join(directory, 'first-screen.png') })
    const text = await page.evaluate(() => document.body.innerText)
    // Without the login token, should the address still carry it.
    const address = new URL(page.url())
    address.search = ''
    writeFileSync(path.join(directory, 'first-screen.txt'), `${await page.title()}\n${address.href}\n\n${text}\n`)
  } finally {
    await browser.close()
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
