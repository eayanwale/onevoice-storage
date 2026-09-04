<?php
// READ-ONLY inspection: given a fileid, print exactly what storage class
// backs it and what the correct B2 object key would be. Does not modify
// anything, does not touch the live request path, does not affect any
// user-facing behavior. Uses the same bootstrap occ itself uses.
//
// Usage: sudo -u nginx php inspect-storage-key.php <fileid> [<fileid> ...]
//
// Findings from running this against real data (see #93):
// - Primary/home:: storage is genuinely local disk here, NOT B2 --
//   corrects an earlier wrong assumption from misreading #76's loose
//   wording. Confirmed against 8 real files across multiple users, all
//   consistently fell through as "neither known type" -- correct, since
//   they really aren't B2-backed.
// - Only the external "OneVoice" AmazonS3 mount is actually B2-backed in
//   this deployment. Its internalPath IS the correct B2 object key, as-is.
// - Every storage gets wrapped by OCA\Files_Trashbin\Storage generically
//   (it intercepts future deletes for every file, not just trashed ones)
//   -- get_class() alone is misleading; instanceOfStorage() correctly
//   sees through wrapper layers to the real backing storage.

require_once '/var/www/nextcloud/lib/base.php';

// Mounts resolve per-user and are set up lazily -- getById() sees nothing
// until a user's filesystem context is initialized. Read-only, matches the
// same pattern Nextcloud's own ShareController uses internally.
\OC_Util::setupFS('admin');

if ($argc < 2) {
	fwrite(STDERR, "Usage: php inspect-storage-key.php <fileid> [<fileid> ...]\n");
	exit(1);
}

$rootFolder = \OC::$server->get(\OCP\Files\IRootFolder::class);

foreach (array_slice($argv, 1) as $fileid) {
	echo "=== fileid {$fileid} ===\n";
	try {
		$nodes = $rootFolder->getById((int)$fileid);
		if (empty($nodes)) {
			echo "  NOT FOUND\n\n";
			continue;
		}
		$node = $nodes[0];
		$storage = $node->getStorage();
		$internalPath = $node->getInternalPath();

		echo "  path (as seen by owner): " . $node->getPath() . "\n";
		echo "  internalPath (relative to storage root): {$internalPath}\n";
		echo "  storage class (outermost wrapper): " . get_class($storage) . "\n";
		echo "  storage id: " . $storage->getId() . "\n";

		if ($storage->instanceOfStorage(\OCA\Files_External\Lib\Storage\AmazonS3::class)) {
			echo "  -> EXTERNAL STORAGE (AmazonS3). B2 key = internalPath as-is: {$internalPath}\n";
		} elseif ($storage->instanceOfStorage(\OC\Files\ObjectStore\ObjectStoreStorage::class)) {
			echo "  -> PRIMARY OBJECTSTORE. B2 key = urn:oid:{$node->getId()} (fileid-based, not path-based)\n";
		} else {
			echo "  -> Neither known B2-backed type -- NOT eligible for direct-download redirect, must fall through to normal proxy\n";
		}
	} catch (\Throwable $e) {
		echo "  ERROR: " . $e->getMessage() . "\n";
	}
	echo "\n";
}
