<?php

declare(strict_types=1);

namespace OCA\DirectDownload\Dav;

use OCA\DAV\Connector\Sabre\File as DavFile;
use OCA\DirectDownload\Service\TokenService;
use OCA\Files_External\Lib\Storage\AmazonS3;
use OCP\IUserSession;
use Sabre\DAV\Exception\NotFound;
use Sabre\DAV\Server;
use Sabre\DAV\ServerPlugin;
use Sabre\HTTP\RequestInterface;
use Sabre\HTTP\ResponseInterface;

/**
 * Redirects non-mobile GET requests for files on the B2-backed external
 * "OneVoice" storage straight to the direct-download Worker, instead of
 * this server proxying the bytes. See #91/#93.
 *
 * Deliberately conservative: falls through to Sabre's normal GET handling
 * (returns true, does nothing) unless EVERY condition is met -- mobile
 * traffic, non-file nodes, non-B2-backed storage, a missing/disabled
 * config, and a user not yet on the staged-rollout allowlist (#94) all
 * fall through safely to the existing, working proxy path. Never
 * redirects to a URL that couldn't be minted.
 *
 * Hook pattern (event name, priority 90, node-from-path extraction) is
 * modeled directly on Nextcloud core's own ViewOnlyPlugin
 * (apps/dav/lib/DAV/ViewOnlyPlugin.php), which intercepts GET at this
 * exact layer for a different purpose.
 */
class DirectDownloadPlugin extends ServerPlugin {
	private ?Server $server = null;

	public function __construct(
		private TokenService $tokenService,
		private IUserSession $userSession,
	) {
	}

	public function initialize(Server $server): void {
		$this->server = $server;
		// Priority 90: same as ViewOnlyPlugin, runs before
		// Sabre\DAV\CorePlugin::httpGet actually streams file content.
		$this->server->on('method:GET', [$this, 'maybeRedirect'], 90);
	}

	private function isMobileApp(string $userAgent): bool {
		return (bool) preg_match('/Nextcloud-(iOS|Android)\//i', $userAgent);
	}

	public function maybeRedirect(RequestInterface $request, ResponseInterface $response): bool {
		if (!$this->tokenService->isRedirectEnabled()) {
			return true;
		}

		$userAgent = $request->getHeader('User-Agent') ?? '';
		if ($this->isMobileApp($userAgent)) {
			return true;
		}

		$user = $this->userSession->getUser();
		if ($user === null || !$this->tokenService->isUserAllowed($user->getUID())) {
			// Staged-rollout allowlist (#94) -- fails closed. No user, or a
			// user not yet opted in, gets the normal proxy path.
			return true;
		}

		try {
			assert($this->server !== null);
			$davNode = $this->server->tree->getNodeForPath($request->getPath());
		} catch (NotFound $e) {
			return true; // let Sabre's normal 404 handling proceed
		}

		if (!($davNode instanceof DavFile)) {
			return true; // directories, versions, etc. -- not in scope
		}

		$node = $davNode->getNode();
		$storage = $node->getStorage();

		if (!$storage->instanceOfStorage(AmazonS3::class)) {
			// Not the B2-backed external storage -- e.g. plain local-disk
			// home directory. Genuinely not eligible; must not redirect.
			return true;
		}

		$key = $node->getInternalPath();
		$redirectUrl = $this->tokenService->mintRedirectUrl($key, $node->getName());

		if ($redirectUrl === null) {
			// Enabled but misconfigured (no secret/worker URL set) --
			// fail safe to the normal proxy, never redirect to nowhere.
			return true;
		}

		$response->setStatus(302);
		$response->setHeader('Location', $redirectUrl);
		return false;
	}
}
