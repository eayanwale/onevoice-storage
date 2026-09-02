<?php

declare(strict_types=1);

namespace OCA\DirectDownload\Service;

use OCP\IConfig;

/**
 * Mints signed tokens for the direct-download Worker. Same scheme as
 * cloudflare/direct-download-worker/worker.js and proven cross-compatible
 * with it in mint-token.php (see #93) -- token = base64url(json payload)
 * "." base64url(HMAC-SHA256 signature), payload = { key, exp, filename }.
 */
class TokenService {
	public function __construct(
		private IConfig $config,
	) {
	}

	public function isEnabled(): bool {
		return $this->config->getAppValue('direct_download', 'enabled', 'false') === 'true';
	}

	public function getWorkerBaseUrl(): ?string {
		$url = $this->config->getAppValue('direct_download', 'worker_base_url', '');
		return $url !== '' ? $url : null;
	}

	private function getSigningSecret(): ?string {
		$secret = $this->config->getAppValue('direct_download', 'signing_secret', '');
		return $secret !== '' ? $secret : null;
	}

	private function base64UrlEncode(string $bytes): string {
		return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
	}

	/**
	 * @return string|null null if not configured (missing secret/worker URL)
	 *                      -- caller must fall through to the normal proxy
	 *                      path in that case, never redirect to nowhere.
	 */
	public function mintRedirectUrl(string $key, string $filename, int $ttlSeconds = 300): ?string {
		$secret = $this->getSigningSecret();
		$baseUrl = $this->getWorkerBaseUrl();
		if ($secret === null || $baseUrl === null) {
			return null;
		}

		$payload = [
			'key' => $key,
			'exp' => time() + $ttlSeconds,
			'filename' => $filename,
		];

		$payloadB64 = $this->base64UrlEncode(json_encode($payload));
		$signature = hash_hmac('sha256', $payloadB64, $secret, true);
		$sigB64 = $this->base64UrlEncode($signature);
		$token = "{$payloadB64}.{$sigB64}";

		$separator = str_contains($baseUrl, '?') ? '&' : '?';
		return "{$baseUrl}{$separator}t={$token}";
	}
}
