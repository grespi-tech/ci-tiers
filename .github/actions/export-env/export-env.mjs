// Appends env lines and selected secrets to $GITHUB_ENV.
//
// Secrets are trimmed when they are single-line: a pasted secret with a
// trailing newline is the classic cause of "credentials are set but rejected"
// (Sparsh's AWS keys, 2026-10). Multi-line secrets (PEM keys) are kept as-is.
import { appendFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const out = process.env.GITHUB_ENV;
const secrets = JSON.parse(process.env.EXPORT_SECRETS_JSON || '{}');

function write(key, value) {
	if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`invalid env name: ${key}`);
	// Heredoc form handles empty and multi-line values alike.
	const eof = `EOF_${randomUUID()}`;
	appendFileSync(out, `${key}<<${eof}\n${value}\n${eof}\n`);
}

// GitHub masks only the exact strings it knows are secrets. A value cut out of
// ENV_SECRETS, or a trimmed secret, is a new string, so it would be printed in
// clear in every later step's env listing. Register each one before export.
// (v1.1.0-v1.2.0 lacked this and leaked ENV_SECRETS values into job logs.)
function writeSecret(key, value) {
	for (const line of value.split('\n')) if (line.trim()) console.log(`::add-mask::${line}`);
	write(key, value);
}

const expand = (value) =>
	value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => process.env[name] ?? '');

for (const raw of (process.env.EXPORT_ENV_LINES || '').split('\n')) {
	const line = raw.trim();
	if (!line || line.startsWith('#')) continue;
	const eq = line.indexOf('=');
	if (eq < 1) throw new Error(`env line is not KEY=VALUE: ${line}`);
	const key = line.slice(0, eq);
	const value = expand(line.slice(eq + 1));
	write(key, value);
	process.env[key] = value; // later lines may reference earlier ones
}

const missing = [];
for (const name of (process.env.EXPORT_SECRET_NAMES || '').split(/\s+/).filter(Boolean)) {
	const value = secrets[name];
	if (value === undefined || value === '') {
		missing.push(name);
		continue;
	}
	writeSecret(name, value.trim().includes('\n') ? value : value.trim());
}

// ENV_SECRETS: KEY=VALUE lines built by the caller from its own secrets. This
// is the only way to hand secrets to a workflow in another owner: `secrets:
// inherit` passes nothing across owners. Values are trimmed and never
// ${VAR}-expanded; an empty value counts as missing.
for (const raw of (process.env.EXPORT_SECRET_LINES || '').split('\n')) {
	const line = raw.trim();
	if (!line || line.startsWith('#')) continue;
	const eq = line.indexOf('=');
	if (eq < 1) throw new Error('ENV_SECRETS line is not KEY=VALUE');
	const key = line.slice(0, eq);
	const value = line.slice(eq + 1).trim();
	if (!value) {
		missing.push(key);
		continue;
	}
	writeSecret(key, value);
}
// Warn rather than fail: a suite may legitimately skip what a missing secret
// would enable, and its own guards decide whether that is fatal.
if (missing.length) console.log(`::warning::secrets not set in this repo: ${missing.join(', ')}`);
