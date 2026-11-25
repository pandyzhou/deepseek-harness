// Prints the names the service is to accept in the Host header, separated by
// spaces: the one of DSH_PUBLIC_URL, then each of DSH_TRUSTED_HOSTS.
//
// The service refuses to start on an entry that is not exactly `host` or
// `host:port`, so every entry is brought into that form here, and one that
// cannot be is reported before anything starts.

function fail(message) {
  console.error(message)
  process.exit(1)
}

// The name a browser sends for this address: it leaves out the port that is
// the default of the scheme, and the service compares a written port exactly.
function nameOfUrl(text) {
  let url
  try { url = new URL(text) } catch { return undefined }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return undefined
  if (url.username || url.password || !url.hostname) return undefined
  return url.port ? `${url.hostname}:${url.port}` : url.hostname
}

// `host` or `host:port` as written; a port is kept even when it is 80 or 443.
function nameOfEntry(text) {
  let http, https
  try {
    http = new URL(`http://${text}`)
    https = new URL(`https://${text}`)
  } catch { return undefined }
  if (http.username || http.password || http.pathname !== '/' || http.search || http.hash) return undefined
  const port = http.port || https.port
  return port ? `${http.hostname}:${port}` : http.hostname
}

const names = []

const publicUrl = (process.env.DSH_PUBLIC_URL || '').trim()
if (publicUrl) {
  const name = nameOfUrl(publicUrl)
  if (!name) fail(`DSH_PUBLIC_URL 不是一个网址：${publicUrl}（应当形如 https://tavern.example.com/）`)
  names.push(name)
}

for (const entry of (process.env.DSH_TRUSTED_HOSTS || '').split(/[\s,]+/).filter(Boolean)) {
  const name = entry.includes('://') ? nameOfUrl(entry) : nameOfEntry(entry)
  if (!name) fail(`DSH_TRUSTED_HOSTS 里的 ${entry} 不是域名：应当形如 tavern.example.com 或 tavern.example.com:8443`)
  names.push(name)
}

console.log([...new Set(names)].join(' '))
