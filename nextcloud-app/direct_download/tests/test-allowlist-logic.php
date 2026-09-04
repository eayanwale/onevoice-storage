<?php
// Standalone test of the allowlist parsing logic (mirrors
// TokenService::isUserAllowed exactly) -- fail-closed semantics for the
// staged rollout (#94): unset/empty means no one, "*" means everyone,
// otherwise a comma-separated list of exact usernames.

function isUserAllowed(string $raw, string $uid): bool {
	$raw = trim($raw);
	if ($raw === '') {
		return false;
	}
	if ($raw === '*') {
		return true;
	}
	$allowed = array_map('trim', explode(',', $raw));
	return in_array($uid, $allowed, true);
}

$cases = [
	['', 'admin', false, 'unset/empty config -- fail closed, no one allowed'],
	['   ', 'admin', false, 'whitespace-only config -- also fail closed'],
	['*', 'admin', true, 'wildcard allows anyone'],
	['*', 'literally-anyone', true, 'wildcard allows anyone, not just known users'],
	['admin', 'admin', true, 'exact single-user match'],
	['admin', 'eayanwale', false, 'not in a single-user list'],
	['admin,eayanwale,dcole', 'eayanwale', true, 'match within a comma list'],
	['admin, eayanwale , dcole', 'eayanwale', true, 'whitespace around list entries is trimmed'],
	['admin,eayanwale', 'admi', false, 'must be exact match, not a prefix'],
	['admino', 'admin', false, 'must be exact match, not a substring'],
];

$failures = 0;
foreach ($cases as [$raw, $uid, $expected, $label]) {
	$actual = isUserAllowed($raw, $uid);
	$status = $actual === $expected ? 'ok  ' : 'FAIL';
	if ($actual !== $expected) $failures++;
	echo "{$status} - {$label}: isUserAllowed(\"{$raw}\", \"{$uid}\") = " . ($actual ? 'true' : 'false') . "\n";
}

echo "\n";
echo $failures > 0 ? "{$failures} check(s) FAILED\n" : "All checks passed.\n";
exit($failures > 0 ? 1 : 0);
