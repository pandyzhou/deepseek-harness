// Prints the value that is kept for the password in DSH_LOGIN_PASSWORD, for the
// gate to compare logins with.
//
//   node login-hash.cjs <file with the secret of the data directory>
const { readFileSync } = require('node:fs')
const { deriveSync, SHORTEST } = require('./login-common.cjs')

const password = process.env.DSH_LOGIN_PASSWORD || ''
if ([...password].length < SHORTEST) {
  console.error(`DSH_LOGIN_PASSWORD 太短：至少要 ${SHORTEST} 个字符。知道这个密码的人就能在容器里执行命令。`)
  process.exit(1)
}
const secret = Buffer.from(readFileSync(process.argv[2], 'utf8').trim(), 'base64')
if (secret.length < 32) {
  console.error(`${process.argv[2]} 的内容不完整，删掉它再启动（已登录的浏览器需要重新登录）。`)
  process.exit(1)
}
console.log(deriveSync(password, secret).toString('hex'))
