# SIDtune website

The public support site for the SIDtune iOS app: plain static HTML and CSS, no build step. The App Store listing links here.

| Page | File | Use in App Store Connect |
|---|---|---|
| Home | `index.html` | Marketing URL |
| User guide | `guide.html` | |
| Privacy Policy | `privacy.html` | Privacy Policy URL |
| Support | `support.html` | Support URL |

Shared styles are in `style.css` (colours from the app's SIDtune Purple theme in `SIDtune/UI/Theme.swift`). The header and footer are
repeated in each page, so a nav change has to be made in all four. `_redirects` maps a few guessable paths (`/contact`, `/help`,
`/manual`) to the right page on Cloudflare Pages. `fonts/PetMe64.ttf` is Kreative Korp's font, redistributed unmodified with its licence.

When the app changes, keep `guide.html` in step with `SIDtune/Resources/Docs/MANUAL.md`, and update `privacy.html` (and its "Last
updated" date) if what the app stores or sends changes.

## Preview locally

```bash
python3 -m http.server 8787 --directory website
```

Then open http://127.0.0.1:8787/.

## Deploy to Cloudflare Pages

With Wrangler (direct upload, no Git integration needed):

```bash
npx wrangler pages deploy website --project-name sidtune
```

The first run asks you to log in and creates the project; the site is then at `https://sidtune.pages.dev` (or the name Cloudflare
gives it if that is taken). Run the same command again to publish changes.

Or from the dashboard: **Workers & Pages → Create → Pages → Connect to Git**, pick `marian8090/sidtune-ios`, set the framework preset
to *None*, leave the build command empty and set the build output directory to `website`. Every push to `main` then redeploys.

Cloudflare Pages serves `privacy.html` at `/privacy` too, so either form works in App Store Connect, e.g.
`https://sidtune.pages.dev/privacy` and `https://sidtune.pages.dev/support`.
