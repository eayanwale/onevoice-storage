// Manual test-token minter for Phase 1 hand-testing (#92). Run this
// yourself, locally, with your own WORKER_SIGNING_SECRET -- it never needs
// to be shared with anyone else to test the deployed Worker.
//
// Usage:
//   node mint-test-token.mjs "<signing-secret>" "<B2 object key>" [ttl-seconds]
//
// Example:
//   node mint-test-token.mjs "my-secret" "OneVoice/Documents/test.pdf" 300
//
// Prints a ready-to-use curl command against your deployed Worker URL.

const [, , secret, key, ttlArg] = process.argv;

if (!secret || !key) {
	console.error('Usage: node mint-test-token.mjs "<signing-secret>" "<B2 object key>" [ttl-seconds]');
	process.exit(1);
}

const ttl = ttlArg ? parseInt(ttlArg, 10) : 300;

function base64UrlEncode(bytes) {
	let bin = '';
	for (const b of bytes) bin += String.fromCharCode(b);
	return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function mintToken(payload, secret) {
	const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
	const payloadB64 = base64UrlEncode(payloadBytes);

	const cryptoKey = await crypto.subtle.importKey(
		'raw', new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
	);
	const sig = await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(payloadB64));
	const sigB64 = base64UrlEncode(new Uint8Array(sig));

	return `${payloadB64}.${sigB64}`;
}

const exp = Math.floor(Date.now() / 1000) + ttl;
const token = await mintToken({ key, exp, filename: key.split('/').pop() }, secret);

console.log('');
console.log(`Token expires in ${ttl}s (unix ${exp}).`);
console.log('');
console.log('Test with:');
console.log(`  curl -i "https://<your-worker>.workers.dev/?t=${token}"`);
console.log('');
console.log('To confirm rejection works, wait for it to expire and try again --');
console.log('should get 403. Or edit the key above by one character and re-mint --');
console.log('should also get 403 (signature won\'t match the tampered payload).');
