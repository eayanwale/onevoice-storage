// direct-download-worker — streams a B2 object straight from B2 to the
// client, bypassing the Bluehost VPS as a byte-relay.
//
// This Worker makes NO authorization decisions of its own. Nextcloud
// (server-side, after its own normal share/permission checks already pass)
// mints a short-lived signed token and hands the client a URL pointing here.
// This Worker's only job is: verify the token is genuine and unexpired, then
// stream the corresponding B2 object. If the token doesn't verify, nothing
// is served — fail closed, always.
//
// Token format: "<base64url(payload json)>.<base64url(HMAC-SHA256 signature)>"
// payload = { key: "<B2 object key>", exp: <unix seconds>, filename?: "<name>" }
//
// Expiry is checked once, when the request arrives — not re-checked mid
// stream — so a large download that runs past the token's expiry still
// finishes once it has legitimately started.
//
// See #92 for the phase this belongs to and #91 for the overall project.

import { AwsClient } from 'aws4fetch';

function base64UrlDecode(str) {
	str = str.replace(/-/g, '+').replace(/_/g, '/');
	while (str.length % 4) str += '=';
	const bin = atob(str);
	const bytes = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	return bytes;
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
		'raw',
		new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['verify']
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

// Types the browser can display itself are served inline so the Nextcloud
// Viewer (and opening a file in a tab) shows them instead of saving them.
// Everything else stays an attachment. See #121.
function isInlineType(contentType) {
	const t = (contentType || '').split(';')[0].trim().toLowerCase();
	return /^(image|video|audio)\//.test(t) || t === 'application/pdf';
}

// The token in the URL is the credential (no cookies), so any origin may
// read the response. It has to be "*": after Nextcloud's cross-origin 302
// the browser sends `Origin: null`, which no specific allowlist would match.
const CORS_HEADERS = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges, Content-Disposition, ETag',
};

export default {
	async fetch(request, env) {
		if (request.method === 'OPTIONS') {
			return new Response(null, {
				status: 204,
				headers: {
					...CORS_HEADERS,
					'Access-Control-Allow-Methods': 'GET, HEAD',
					'Access-Control-Allow-Headers': 'Range',
					'Access-Control-Max-Age': '86400',
				},
			});
		}

		if (request.method !== 'GET' && request.method !== 'HEAD') {
			return new Response('Method not allowed', { status: 405 });
		}

		const url = new URL(request.url);
		const token = url.searchParams.get('t');

		const payload = await verifyToken(token, env.WORKER_SIGNING_SECRET);
		if (!payload) {
			return new Response('Invalid or expired token', { status: 403 });
		}

		const b2 = new AwsClient({
			accessKeyId: env.B2_READONLY_KEY_ID,
			secretAccessKey: env.B2_READONLY_APPLICATION_KEY,
			service: 's3',
			region: env.B2_REGION,
		});

		const objectUrl = `https://${env.B2_BUCKET}.${env.B2_HOSTNAME}/${payload.key}`;

		const forwardHeaders = {};
		const rangeHeader = request.headers.get('Range');
		if (rangeHeader) forwardHeaders['Range'] = rangeHeader;

		const signedRequest = await b2.sign(objectUrl, {
			method: request.method,
			headers: forwardHeaders,
		});

		const b2Response = await fetch(signedRequest);

		if (b2Response.status >= 400) {
			// Do not leak B2's raw error body/headers to the client.
			return new Response('Upstream storage error', { status: 502 });
		}

		const headers = new Headers();
		for (const h of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag']) {
			const v = b2Response.headers.get(h);
			if (v) headers.set(h, v);
		}
		headers.set('Cache-Control', 'private, no-store');
		for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
		if (payload.filename) {
			const safe = payload.filename.replace(/["\r\n]/g, '');
			const disposition = isInlineType(headers.get('content-type')) ? 'inline' : 'attachment';
			headers.set('Content-Disposition', `${disposition}; filename="${safe}"`);
		}

		return new Response(b2Response.body, {
			status: b2Response.status,
			headers,
		});
	},
};
