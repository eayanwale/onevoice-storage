// Standalone correctness test for the token scheme, independent of the
// Worker runtime and aws4fetch, so it can run with plain `node` — no
// deployment, no Cloudflare account, no B2 credentials needed.
//
// This also doubles as the reference implementation for what Nextcloud's
// PHP side (Phase 2, #93) needs to replicate byte-for-byte: same base64url
// encoding, same HMAC-SHA256 over the same payload bytes.

function base64UrlEncode(bytes) {
	let bin = '';
	for (const b of bytes) bin += String.fromCharCode(b);
	return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlDecode(str) {
	str = str.replace(/-/g, '+').replace(/_/g, '/');
	while (str.length % 4) str += '=';
	const bin = atob(str);
	const bytes = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	return bytes;
}

async function mintToken(payload, secret) {
	const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
	const payloadB64 = base64UrlEncode(payloadBytes);

	const key = await crypto.subtle.importKey(
		'raw', new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
	);
	const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payloadB64));
	const sigB64 = base64UrlEncode(new Uint8Array(sig));

	return `${payloadB64}.${sigB64}`;
}

async function verifyToken(token, secret) {
	if (!token || typeof token !== 'string') return null;
	const parts = token.split('.');
	if (parts.length !== 2) return null;
	const [payloadB64, sigB64] = parts;

	let signatureBytes, payloadBytes;
	try {
		signatureBytes = base64UrlDecode(sigB64);
		payloadBytes = base64UrlDecode(payloadB64);
	} catch {
		return null;
	}

	const key = await crypto.subtle.importKey(
		'raw', new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' }, false, ['verify']
	);

	const valid = await crypto.subtle.verify('HMAC', key, signatureBytes, new TextEncoder().encode(payloadB64));
	if (!valid) return null;

	let payload;
	try {
		payload = JSON.parse(new TextDecoder().decode(payloadBytes));
	} catch {
		return null;
	}

	if (!payload || typeof payload.key !== 'string' || typeof payload.exp !== 'number') return null;
	if (Math.floor(Date.now() / 1000) > payload.exp) return null;

	return payload;
}

let failures = 0;
function check(name, cond) {
	if (cond) {
		console.log(`ok   - ${name}`);
	} else {
		console.log(`FAIL - ${name}`);
		failures++;
	}
}

const SECRET = 'test-secret-do-not-use-in-prod';
const now = Math.floor(Date.now() / 1000);

// 1. Valid token round-trips
{
	const token = await mintToken({ key: 'OneVoice/foo.mp4', exp: now + 300, filename: 'foo.mp4' }, SECRET);
	const result = await verifyToken(token, SECRET);
	check('valid token verifies and returns the correct payload', result && result.key === 'OneVoice/foo.mp4' && result.filename === 'foo.mp4');
}

// 2. Expired token is rejected
{
	const token = await mintToken({ key: 'OneVoice/foo.mp4', exp: now - 10 }, SECRET);
	const result = await verifyToken(token, SECRET);
	check('expired token is rejected', result === null);
}

// 3. Tampered payload (different key claimed) is rejected — this is the
//    security-critical case: someone can't just edit which file they want.
{
	const token = await mintToken({ key: 'OneVoice/foo.mp4', exp: now + 300 }, SECRET);
	const [payloadB64, sigB64] = token.split('.');
	const tamperedPayload = base64UrlEncode(new TextEncoder().encode(JSON.stringify({ key: 'OneVoice/private-file.mp4', exp: now + 300 })));
	const tamperedToken = `${tamperedPayload}.${sigB64}`;
	const result = await verifyToken(tamperedToken, SECRET);
	check('tampered payload (signature no longer matches) is rejected', result === null);
}

// 4. Wrong secret (e.g. token forged without knowing the real secret) is rejected
{
	const token = await mintToken({ key: 'OneVoice/foo.mp4', exp: now + 300 }, 'wrong-secret');
	const result = await verifyToken(token, SECRET);
	check('token signed with the wrong secret is rejected', result === null);
}

// 5. Malformed tokens are rejected, not thrown
{
	check('empty string rejected', (await verifyToken('', SECRET)) === null);
	check('garbage string rejected', (await verifyToken('not-a-real-token', SECRET)) === null);
	check('missing signature part rejected', (await verifyToken('onlyonepart', SECRET)) === null);
	check('non-JSON payload rejected', (await verifyToken('bm90LWpzb24.abc', SECRET)) === null);
}

console.log('');
if (failures > 0) {
	console.log(`${failures} check(s) FAILED`);
	process.exit(1);
} else {
	console.log('All checks passed.');
}
