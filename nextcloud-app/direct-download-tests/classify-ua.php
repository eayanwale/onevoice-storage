<?php
// User-Agent classification: is this the mobile app? Everything else
// (browser, desktop client mirall, generic WebDAV clients) is eligible for
// the direct-download redirect; mobile is left completely untouched -- see
// #93 for why mobile is explicitly excluded.
//
// This is a delivery-channel decision, not a security decision -- Nextcloud's
// own permission checks already happened before this runs. A spoofed UA at
// worst routes through the "wrong" channel, never grants unauthorized access.

function isMobileApp(string $userAgent): bool {
	return (bool) preg_match('/Nextcloud-(iOS|Android)\//i', $userAgent);
}

$cases = [
	['Mozilla/5.0 (iOS) Nextcloud-iOS/34.1.4', true, 'iOS app'],
	['Mozilla/5.0 (Android) Nextcloud-Android/3.30.0', true, 'Android app'],
	['Mozilla/5.0 (Windows NT 10.0; Win64; x64) mirall/3.16.2', false, 'desktop client'],
	['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0', false, 'desktop browser'],
	['Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Safari/605.1.15', false, 'Safari browser'],
	['', false, 'empty UA (fail open to redirect -- worst case is wrong channel, not access)'],
	['Nextcloud-iOSSomethingElse/1.0', false, 'must not loosely match a UA that merely contains the substring without the slash boundary'],
];

$failures = 0;
foreach ($cases as [$ua, $expected, $label]) {
	$actual = isMobileApp($ua);
	$status = $actual === $expected ? 'ok  ' : 'FAIL';
	if ($actual !== $expected) $failures++;
	echo "{$status} - {$label}: isMobileApp() = " . ($actual ? 'true' : 'false') . " (expected " . ($expected ? 'true' : 'false') . ")\n";
}

echo "\n";
echo $failures > 0 ? "{$failures} check(s) FAILED\n" : "All checks passed.\n";
exit($failures > 0 ? 1 : 0);
