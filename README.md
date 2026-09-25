# Review Canvas

One link per brief. The strategy sits beside the creative, reviewers drop pinned notes straight onto the ad, and nobody needs an account.

Built at DL Media to replace review feedback scattered across Drive comments, Slack threads and a dozen folder links. This repo is the working demo, loaded with a real past brief.

## What it does

- **One link per brief.** Every deliverable for a brief lives on a single page.
- **The brief travels with the creative.** Hypothesis, how it is measured, the big idea, the Meta copy and the landing page sit in a panel beside the ads, so feedback is judged against the bet rather than against taste.
- **Notes pinned to the pixel.** Click anywhere on an ad to leave a numbered note. Hover a pin to read it. On video, pause and note the exact moment, then click the timestamp to seek back.
- **Reviewers write the copy.** Instead of "make the headline punchier", a reviewer types the headline they would run, up to three of each, and the feed preview updates as they type. Toggle any alternative in and out, one at a time.
- **Attachments.** A note can carry a reference image or a link to the asset they want instead.
- **Rounds.** A new upload becomes the next round on the same link. Earlier rounds stay readable.
- **No account.** Reviewers type their name once. Notes are shared with everyone on the link.

## How it is built

A single static page. No server, no build step, no framework.

```
index.html          the whole application
assets/             the demo's creative
```

The page reads and writes notes through a thin storage layer. In this demo that is the Claude artifact `db` capability with a `localStorage` fallback, so it runs from a file with nothing installed. In production that layer is Supabase: Postgres for the notes, Supabase Storage for the media, row level security so a link token grants access to one brief and nothing else.

Swapping the two is one function. Everything else is untouched.

## Running it

Open `index.html` in a browser. That is the whole thing.

To serve it locally:

```bash
python -m http.server 8000
```

## Production shape

```
Google Drive  ->  extract  ->  Supabase (media + notes)  ->  static page on a CDN
                     |
                     +-> writes the link back into the Notion brief
```

- **Drive stays the source of truth.** The app is a review surface, never storage. If it lost everything, the links regenerate from Drive.
- **Nothing of ours is a running server.** A static page plus Supabase plus a job that runs on demand. There is no process to crash.
- **Media is copied, never hot-linked from Drive.** Drive does not serve range requests reliably, so video seeking breaks, so timestamped notes break.
- **Notes never expire.** They are kilobytes and nothing can recreate what a brand owner typed. Media could expire; at current volume it does not need to.

## Deliverable spec this assumes

Set on the brief, enforced nowhere else:

- **Video:** MP4 container, h.264, AAC, 1080 max on the long edge, 3 to 4 Mbps
- **Statics:** PNG or JPEG, 1080 max on the long edge
- Aspect ratio stays per brand

The demo video was delivered at 8.7 Mbps and re-encoded to 3.1 Mbps for this repo. Same resolution and codec, 17.2 MB down to 6.0 MB, no visible difference.

## About the demo content

The creative is OPIN0354 Home Defense, a past brief for a brand that is no longer a client. Those ads ran publicly on Meta, so nothing here is unreleased.

Media is committed to this repo because the demo needs to serve it. In production media never touches git; it lives in object storage.

## Status

Working demo. Not yet used on a live brief.

Open decisions, all defaulted to the simplest option for now: no approve button, every round visible to everyone, notes on creative and copy only, no done state on notes.

Known limit: a reviewer's name identifies them, it does not authenticate them. Fine among colleagues, worth replacing with a per-reviewer link token before this carries client work.
