import crypto from 'node:crypto';
import fs from 'node:fs';
import dotenv from 'dotenv';

const envPath = '.env';
const content = fs.readFileSync(envPath, 'utf8');
const parsed = dotenv.parse(content);
const defaults = {
  API_KEY: `sk-${crypto.randomBytes(24).toString('hex')}`,
  ADMIN_USERNAME: `admin-${crypto.randomBytes(6).toString('hex')}`,
  ADMIN_PASSWORD: crypto.randomBytes(24).toString('hex'),
  JWT_SECRET: crypto.randomBytes(32).toString('hex')
};
const missing = Object.entries(defaults).filter(([key]) => !parsed[key]);

if (missing.length) {
  let updated = content;
  const missingValues = new Map(missing);

  for (const [key, value] of missing) {
    const assignment = new RegExp(`^(\\s*(?:export\\s+)?${key}\\s*=).*$`, 'gm');
    if (assignment.test(updated)) {
      updated = updated.replace(assignment, `${key}=${value}`);
      missingValues.delete(key);
    }
  }

  if (missingValues.size) {
    updated = `${updated}${updated.endsWith('\n') ? '' : '\n'}\n${[...missingValues]
      .map(([key, value]) => `${key}=${value}`)
      .join('\n')}\n`;
  }

  fs.writeFileSync(envPath, updated);
}

fs.chmodSync(envPath, 0o600);
