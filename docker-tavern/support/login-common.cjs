// What the entrypoint and the gate share about the login: how a password is
// turned into the value that is kept and compared, and the limits on it.
const crypto = require('node:crypto')

const COST = { N: 16384, r: 8, p: 1 }
const LENGTH = 32

// The shortest password that is accepted when the container starts.
exports.SHORTEST = 8

/**
 * The value kept for a password: nothing that runs in the container after the
 * entrypoint has the password itself.
 * @param {string} password as typed.
 * @param {Buffer} secret the random bytes of this data directory, as the salt.
 * @returns {Promise<Buffer>}
 */
exports.derive = (password, secret) => new Promise((resolve, reject) => {
  crypto.scrypt(password, secret, LENGTH, COST, (error, key) => (error ? reject(error) : resolve(key)))
})

exports.deriveSync = (password, secret) => crypto.scryptSync(password, secret, LENGTH, COST)
