import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto';

export const refreshIssuer = 'https://payroll-refresh.example.test';
const keyId = 'payroll-refresh-fixture';

export function refreshJwk() {
  process.env.E2E_REFRESH_SIGNING_KEY ??= generateKeyPairSync('rsa', { modulusLength: 2048 })
    .privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  return { ...createPublicKey(process.env.E2E_REFRESH_SIGNING_KEY).export({ format: 'jwk' }), kid: keyId };
}

export function refreshSession(subject: string, origin: string, age: number) {
  const key = createPrivateKey(process.env.E2E_REFRESH_SIGNING_KEY!);
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const data = [
    encode({ alg: 'RS256', kid: keyId }),
    encode({ sub: subject, iss: refreshIssuer, azp: origin, iat: now, exp: now + 300,
      sid: `fixture_${subject}`, fva: [age, age], two_factor_enabled: true }),
  ].join('.');
  return `Bearer ${data}.${sign('RSA-SHA256', Buffer.from(data), key).toString('base64url')}`;
}
