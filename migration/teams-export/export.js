// One-time export of a Microsoft Teams (consumer) Community into Nextcloud-importable
// files: events.ics (Calendar), links.html (Bookmarks, Netscape format), and a
// files/<channel>/ tree of downloaded attachments.
//
// Setup:
//   npm install
//   npx playwright install chromium
//
// Run:
//   node export.js <ChannelName1> <ChannelName2> ...
//
// The browser opens headed and stays logged in via a local profile dir (.browser-profile),
// so MFA only has to happen once. Community/channel/Events navigation is automated via the
// app's ARIA roles (role="treeitem" in the sidebar, named buttons) — confirmed by recording
// a real session with `npx playwright codegen https://teams.live.com/v2/`.
//
// STILL A TODO: the selectors inside extractEvents()/extractPosts() and the two scroll
// container selectors are placeholders — codegen only recorded navigation, not the DOM
// inside an opened event or a message with a link/attachment. To fill those in:
//   npx playwright codegen https://teams.live.com/v2/
// then, once logged in and inside the community: open the Events tab and click one event
// card, and separately open a channel and hover/click a message that has a link or a file
// attachment — read off what codegen records (or just inspect with DevTools) and paste it
// back so the TODOs below can be replaced with the real thing.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const BASE_URL = 'https://teams.live.com/v2/';
const COMMUNITY_NAME = 'OneVoice';

const OUTPUT_DIR = path.join(__dirname, 'output');
const USER_DATA_DIR = path.join(__dirname, '.browser-profile');

fs.mkdirSync(path.join(OUTPUT_DIR, 'files'), { recursive: true });

function waitForEnter(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(prompt, () => {
      rl.close();
      resolve();
    });
  });
}

// Teams virtualizes long lists, so DOM nodes recycle as you scroll — we re-read
// whatever's currently rendered after each scroll step and accumulate by key,
// stopping once a few scrolls in a row add nothing new.
async function scrollAndCollect(page, containerSelector, extract, { maxStableRounds = 3, scrollDelay = 800 } = {}) {
  const seen = new Map();
  let stableRounds = 0;
  let lastCount = -1;

  while (stableRounds < maxStableRounds) {
    const items = await extract(page);
    for (const item of items) seen.set(item.key, item);

    if (seen.size === lastCount) {
      stableRounds++;
    } else {
      stableRounds = 0;
      lastCount = seen.size;
    }

    await page.$eval(containerSelector, (el) => el.scrollBy(0, el.clientHeight * 0.8)).catch(() => {});
    await page.waitForTimeout(scrollDelay);
  }

  return [...seen.values()];
}

// ---- ICS ----

function icsEscape(str = '') {
  return str.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
}

function toIcsDate(d) {
  return d.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
}

function buildIcs(events) {
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//onevoice//teams-export//EN'];
  for (const ev of events) {
    lines.push(
      'BEGIN:VEVENT',
      `UID:${ev.id}@teams-export`,
      `DTSTAMP:${toIcsDate(new Date())}`,
      `DTSTART:${toIcsDate(ev.start)}`,
      `DTEND:${toIcsDate(ev.end || new Date(ev.start.getTime() + 60 * 60 * 1000))}`,
      `SUMMARY:${icsEscape(ev.title)}`,
      ev.location ? `LOCATION:${icsEscape(ev.location)}` : null,
      ev.description ? `DESCRIPTION:${icsEscape(ev.description)}` : null,
      'END:VEVENT'
    );
  }
  lines.push('END:VCALENDAR');
  return lines.filter(Boolean).join('\r\n');
}

// ---- Bookmarks (Netscape HTML format — importable by Nextcloud's Bookmarks app) ----

function buildBookmarksHtml(links) {
  const items = links
    .map((l) => `    <DT><A HREF="${l.url}" ADD_DATE="${Math.floor(Date.now() / 1000)}">${l.title || l.url}</A>`)
    .join('\n');
  return `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
${items}
</DL><p>
`;
}

// ---- Extraction (TEAMS-SPECIFIC — fill in real selectors before running for real) ----

async function extractEvents(page) {
  // TODO: confirm against the live DOM (npx playwright codegen)
  return page.$$eval('[data-tid="event-card"]', (cards) =>
    cards.map((c) => ({
      key: c.getAttribute('data-event-id') || c.textContent,
      id: c.getAttribute('data-event-id') || Math.random().toString(36).slice(2),
      title: c.querySelector('[data-tid="event-title"]')?.textContent?.trim() || '',
      startIso: c.querySelector('time')?.getAttribute('datetime') || null,
      location: c.querySelector('[data-tid="event-location"]')?.textContent?.trim() || '',
      description: c.querySelector('[data-tid="event-description"]')?.textContent?.trim() || '',
    }))
  );
}

async function extractPosts(page) {
  // TODO: confirm against the live DOM (npx playwright codegen)
  return page.$$eval('[data-tid="chat-pane-message"]', (msgs) =>
    msgs.map((m) => ({
      key: m.getAttribute('id') || m.textContent.slice(0, 50),
      author: m.querySelector('[data-tid="message-author-name"]')?.textContent?.trim() || '',
      text: m.querySelector('[data-tid="message-body-content"]')?.textContent?.trim() || '',
      links: [...m.querySelectorAll('a[href]')].map((a) => ({ url: a.href, title: a.textContent.trim() })),
      attachments: [...m.querySelectorAll('[data-tid="file-attachment"] a[href]')].map((a) => ({
        url: a.href,
        name: a.textContent.trim(),
      })),
    }))
  );
}

// ---- Navigation (recorded via playwright codegen against a real session) ----

async function login(page) {
  await page.goto(BASE_URL);
  await waitForEnter('Log into Teams in the opened window (including MFA), then press Enter here to continue...');
  // "Stay signed in?" prompt doesn't always appear (persistent profile may skip it on reruns).
  await page
    .getByTestId('primaryButton')
    .click({ timeout: 5000 })
    .catch(() => {});
}

async function openCommunity(page, communityName) {
  await page.getByRole('button', { name: 'Communities' }).click();
  await page.getByRole('tree', { name: 'Communities' }).getByText(communityName).click();
}

async function openChannel(page, channelName) {
  await page.getByRole('treeitem', { name: channelName }).click();
}

async function openEvents(page) {
  await page.getByRole('button', { name: 'Events' }).click();
}

async function downloadAttachment(page, url, destPath) {
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 15000 }).catch(() => null),
    page.evaluate((href) => {
      const a = document.createElement('a');
      a.href = href;
      a.download = '';
      document.body.appendChild(a);
      a.click();
      a.remove();
    }, url),
  ]);
  if (download) {
    await download.saveAs(destPath);
    return true;
  }
  return false;
}

async function main() {
  const channelNames = process.argv.slice(2);
  if (channelNames.length === 0) {
    console.log('Usage: node export.js <ChannelName1> <ChannelName2> ...');
  }

  const browser = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    viewport: { width: 1400, height: 900 },
    acceptDownloads: true,
  });
  const page = browser.pages()[0] || (await browser.newPage());

  await login(page);
  await openCommunity(page, COMMUNITY_NAME);

  // ---- Events ----
  await openEvents(page);
  if (process.env.INSPECT) {
    console.log('Paused for inspection. In the Playwright Inspector window, click "Pick locator" then click an event card.');
    await page.pause();
  }
  const rawEvents = await scrollAndCollect(page, '[data-tid="events-list-scroll-container"]', extractEvents);
  const events = rawEvents.filter((e) => e.startIso).map((e) => ({ ...e, start: new Date(e.startIso) }));
  fs.writeFileSync(path.join(OUTPUT_DIR, 'events.ics'), buildIcs(events));
  console.log(`Wrote ${events.length} events to output/events.ics`);

  // ---- Channels ----
  const allLinks = [];
  for (const channelName of channelNames) {
    const safeName = channelName.replace(/[\\/:*?"<>|]/g, '-');

    await openChannel(page, channelName);
    if (process.env.INSPECT) {
      console.log('Paused for inspection. Click "Pick locator" then click a message (ideally one with a link/attachment).');
      await page.pause();
    }
    const posts = await scrollAndCollect(page, '[data-tid="message-pane-list-scroll-container"]', extractPosts);
    console.log(`"${channelName}": found ${posts.length} posts`);

    const channelDir = path.join(OUTPUT_DIR, 'files', safeName);
    fs.mkdirSync(channelDir, { recursive: true });

    for (const post of posts) {
      for (const link of post.links) {
        allLinks.push({ ...link, title: `${channelName}: ${link.title || link.url}` });
      }
      for (const att of post.attachments) {
        const dest = path.join(channelDir, att.name || `attachment-${Date.now()}`);
        const ok = await downloadAttachment(page, att.url, dest);
        console.log(`${ok ? 'Downloaded' : 'FAILED'}: ${channelName}/${att.name}`);
      }
    }

    fs.writeFileSync(path.join(OUTPUT_DIR, `${safeName}-posts.json`), JSON.stringify(posts, null, 2));
  }

  fs.writeFileSync(path.join(OUTPUT_DIR, 'links.html'), buildBookmarksHtml(allLinks));
  console.log(`Wrote ${allLinks.length} links to output/links.html`);

  await browser.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
