<?php
// Standalone PHP token minter -- mirrors the JS logic in
// cloudflare/direct-download-worker/test-token.mjs exactly, proven
// cross-compatible with the deployed Worker (see #93). Not part of
// Nextcloud, not deployed anywhere -- a reusable proof/debug tool.
//
// Usage: php mint-token.php "<signing-secret>" "<B2 object key>" [ttl-seconds]

function base64UrlEncode(string $bytes): string {
	return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
}

function mintToken(array $payload, string $secret): string {
	$payloadJson = json_encode($payload);
	$payloadB64 = base64UrlEncode($payloadJson);
	$signature = hash_hmac('sha256', $payloadB64, $secret, true);
	$sigB64 = base64UrlEncode($signature);
	return "{$payloadB64}.{$sigB64}";
}

if ($argc < 3) {
	fwrite(STDERR, "Usage: php mint-token.php \"<signing-secret>\" \"<B2 object key>\" [ttl-seconds]\n");
	exit(1);
}

[$_, $secret, $key] = $argv;
$ttl = isset($argv[3]) ? (int)$argv[3] : 300;
$exp = time() + $ttl;

$token = mintToken(['key' => $key, 'exp' => $exp, 'filename' => basename($key)], $secret);

echo "\n";
echo "Token expires in {$ttl}s (unix {$exp}).\n";
echo "\n";
echo "This is a PHP-minted token, testing cross-language compatibility with the JS Worker.\n";
echo "Test with:\n";
echo "  curl -i \"https://onevoice-direct-download-test.enochayanwale.workers.dev/?t={$token}\"\n";
echo "\n";
