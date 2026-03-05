import { env } from '@Caterm/env/server'
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto'

const ALGORITHM = 'aes-256-gcm'
const IV_LENGTH = 16
const AUTH_TAG_LENGTH = 16
const MIN_ENCRYPTED_LENGTH = IV_LENGTH + AUTH_TAG_LENGTH + 1

const KEY = Buffer.from(env.ENCRYPTION_KEY, 'hex')

export function encrypt(plaintext: string): string {
  const iv = randomBytes(IV_LENGTH)
  const cipher = createCipheriv(ALGORITHM, KEY, iv)
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()])
  const authTag = cipher.getAuthTag()
  const combined = Buffer.concat([iv, authTag, encrypted])
  return combined.toString('base64')
}

export function decrypt(encrypted: string): string {
  const combined = Buffer.from(encrypted, 'base64')
  if (combined.length < MIN_ENCRYPTED_LENGTH) {
    throw new Error('Invalid encrypted data: buffer too short')
  }
  const iv = combined.subarray(0, IV_LENGTH)
  const authTag = combined.subarray(IV_LENGTH, IV_LENGTH + AUTH_TAG_LENGTH)
  const ciphertext = combined.subarray(IV_LENGTH + AUTH_TAG_LENGTH)
  const decipher = createDecipheriv(ALGORITHM, KEY, iv)
  decipher.setAuthTag(authTag)
  return decipher.update(ciphertext, undefined, 'utf8') + decipher.final('utf8')
}
