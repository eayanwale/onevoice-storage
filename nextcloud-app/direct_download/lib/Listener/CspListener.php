<?php

declare(strict_types=1);

namespace OCA\DirectDownload\Listener;

use OCA\DirectDownload\Service\TokenService;
use OCP\AppFramework\Http\EmptyContentSecurityPolicy;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\Security\CSP\AddContentSecurityPolicyEvent;

/**
 * Lets pages load media from the direct-download Worker. Browsers enforce
 * the page's CSP after following a redirect, so without this the Viewer's
 * <video>/<img> loads -- which DirectDownloadPlugin 302s to the Worker --
 * are blocked by Nextcloud's default media-src/img-src 'self' ("Media load
 * rejected by URL safety check", shown as a 503 in devtools). See #121.
 *
 * Only added while the redirect is enabled and the Worker URL is set, so a
 * disabled app widens nothing.
 *
 * @template-implements IEventListener<AddContentSecurityPolicyEvent>
 */
class CspListener implements IEventListener {
	public function __construct(
		private TokenService $tokenService,
	) {
	}

	public function handle(Event $event): void {
		if (!($event instanceof AddContentSecurityPolicyEvent)) {
			return;
		}
		if (!$this->tokenService->isRedirectEnabled()) {
			return;
		}

		$origin = $this->tokenService->getWorkerOrigin();
		if ($origin === null) {
			return;
		}

		$policy = new EmptyContentSecurityPolicy();
		$policy->addAllowedMediaDomain($origin);
		$policy->addAllowedImageDomain($origin);
		// The Viewer fetch()es some files (e.g. to build blob: URLs) rather
		// than pointing an element at them.
		$policy->addAllowedConnectDomain($origin);
		$event->addPolicy($policy);
	}
}
