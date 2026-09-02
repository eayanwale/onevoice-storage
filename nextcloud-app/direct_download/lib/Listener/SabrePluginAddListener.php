<?php

declare(strict_types=1);

namespace OCA\DirectDownload\Listener;

use OCA\DAV\Events\SabrePluginAddEvent;
use OCA\DirectDownload\Dav\DirectDownloadPlugin;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use Psr\Container\ContainerInterface;

/**
 * Registration pattern modeled directly on Nextcloud core's own
 * apps/files_reminders/lib/Listener/SabrePluginAddListener.php -- a real,
 * already-shipping app using this exact mechanism in this NC version.
 *
 * @template-implements IEventListener<SabrePluginAddEvent>
 */
class SabrePluginAddListener implements IEventListener {
	public function __construct(
		private ContainerInterface $container,
	) {
	}

	public function handle(Event $event): void {
		if (!($event instanceof SabrePluginAddEvent)) {
			return;
		}

		$server = $event->getServer();
		$plugin = $this->container->get(DirectDownloadPlugin::class);
		$server->addPlugin($plugin);
	}
}
