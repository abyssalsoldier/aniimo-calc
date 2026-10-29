# Aniimo Homeland Calculator

A small web tool for planning your **Homeland** in *Aniimo*. You tell it which Homeland abilities you need and how many Aniimo your Home can hold, and it works out the smallest team that covers everything.

- **Every Aniimo and form** with its elements and Homeland abilities (Fire, Water, Grass, Earth, Lightning, Ice, Wind, Dark, Light, Hauling, Artisanship, Leisure, Perfumery) and their levels (1–4).
- **Your needs:** for each ability, set a minimum level and the number of workers.
- **Best team:** the fewest Aniimo that meet every need. When two teams are the same size, the one with higher total ability levels wins. The search is exact (branch-and-bound), not a guess.
- **Prismana toggle:** Prismana forms are rare, so they're **excluded by default**. If a need can only be met by a Prismana form, or allowing Prismana would shrink your team, the calculator tells you.
- **Only Aniimo you can own:** bosses and NPC-only creatures are left out.
- **"Only use Aniimo I own"**: tick the Aniimo you have in the list and plan with just those.
- Settings and your owned list are saved in your browser.

## Hosting (Cloudflare Pages)

The calculator is a static site: every calculation runs in the visitor's browser, and the server only hands out a handful of small files from [`site/`](site/). Cloudflare Pages serves those from its global network for free, with no traffic limits on static files, so it copes with any number of visitors. It also redeploys automatically on every push, including the daily data updates.

### One-time setup

1. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** tab → **Connect to Git** (*Import an existing Git repository*).
2. Authorise GitHub if asked, and pick **abyssalsoldier/aniimo-calc**.
3. Build settings:
   - Production branch: `main`
   - Framework preset: **None**
   - Build command: *(leave empty)*
   - Build output directory: **`site`**
4. **Save and Deploy.** After about a minute the site is live at `https://<project>.pages.dev`.
5. Project → **Custom domains** → **Set up a custom domain** → e.g. `calc.yourdomain.com` → **Activate domain**. Your domain is already on Cloudflare, so it creates the DNS record for you. If you'd already pointed that hostname at your tunnel, delete that public hostname first.

After that there's nothing to run or maintain. Every push to `main` (yours, or the data bot's) is live about a minute later. Old deployments are kept under the project's **Deployments** tab, where you can roll back with one click. [`site/_headers`](site/_headers) sets security headers and browser caching.

## Running it locally

To try changes before pushing (no installs needed):

```
start.bat            # http://localhost:8080
start.bat 5173       # pick a port
```

Or run `powershell -ExecutionPolicy Bypass -File serve.ps1 -Port 5173`. Press **Ctrl+C** to stop. This local server is only for testing: it serves `site/` plus the test pages, and only on your own machine.
## Keeping the Aniimo list up to date

The roster lives in [`site/data/aniimo.json`](site/data/aniimo.json), one Aniimo per line. It's built from [AniimoTools](https://aniimotools.dev/creatures/). New species and forms are picked up automatically as the game adds them.

**Automatic (GitHub Actions):** the [Update Aniimo data](.github/workflows/update-data.yml) workflow re-scrapes every day at 06:17 UTC. If anything changed, it commits the new data with a message listing what was added, changed or removed. Cloudflare Pages then redeploys, so the update is live about a minute later. If nothing changed, it does nothing.

- **To run it now:** go to the repo's **Actions** tab → *Update Aniimo data* → *Run workflow*.
- **If it fails**, GitHub emails you. The scraper refuses to write when the scrape looks broken: pages that won't load, lots of entries disappearing, entries where nothing could be parsed (usually means aniimotools.dev changed its page layout), or a Homeland ability name it doesn't know (if the game added one, add it to `$Abilities` in `tools/scrape.ps1`). The run log says which. If you've checked the change is genuine, re-run with **force** ticked.

**By hand:**
```
powershell -ExecutionPolicy Bypass -File tools\scrape.ps1               # everything
powershell -ExecutionPolicy Bypass -File tools\scrape.ps1 -Only tromber,glacy
```
The file is only rewritten when the data actually changed. It also prints a summary of the changes.

**Fixing wrong data:** don't edit `aniimo.json` directly, since the next scrape would undo it. Put corrections in [`tools/overrides.json`](tools/overrides.json). They're applied after every scrape:
```json
{ "patch": {
    "lunara": { "unobtainable": true },
    "glacy": { "abilities": { "Water": 3, "Hauling": 3, "Ice": 2 } }
} }
```
Any field you give replaces the scraped value: `name`, `form`, `prismana`, `unobtainable`, `elements`, or `abilities` (replaces the whole list). `"unobtainable": true` leaves that Aniimo out of the data. Each entry in `aniimo.json` looks like this:
```json
{"id":"tromber-beach","page":"tromber","name":"Tromber","form":"Beach Form","prismana":false,"unobtainable":false,"elements":["Wind","Water"],"abilities":{"Water":2,"Wind":3}}
```
Spotted a mistake? [Open an issue](https://github.com/abyssalsoldier/aniimo-calc/issues).

## Ability pages and search engines

Besides the calculator, the site has a **"Best Aniimo for …" page for each Homeland ability** (e.g. `/abilities/perfumery/`), plus `sitemap.xml` and `robots.txt`. These give Google real pages to show for searches like *"best aniimo for hauling"*.

The ability pages, the sitemap and the ability links on the main page are generated from `aniimo.json` by [`tools/build-pages.ps1`](tools/build-pages.ps1). The scraper runs it automatically whenever the data changes, so you normally never run it yourself. Run it by hand only after changing the page layout in that script:
```
powershell -ExecutionPolicy Bypass -File tools\build-pages.ps1
```
Don't edit `site/abilities/` or `site/sitemap.xml` directly, since the next run overwrites them. In `site/index.html`, everything between the `abilities:start` / `abilities:end` markers is generated too.

The site's address (`https://aniimocalc.com`) appears in `build-pages.ps1` (`$BaseUrl`), `site/index.html` (canonical link and share-preview tags) and `site/robots.txt`. Change all three if the domain changes. `site/og-image.png` is the preview picture shown when the link is shared on Discord, Reddit and similar sites.

## Icons

Each element and Homeland ability has an icon. Official game icons are used where available. Any ability without one falls back to a hand-drawn icon in [`site/js/icons.js`](site/js/icons.js).

To add official icons:
1. Put the images in [`site/icons/`](site/icons/). PNG or WebP with a transparent background works best, at least 64×64 and square. The site shows them at about 16–20 px.
2. List them in [`site/icons/icons.json`](site/icons/icons.json) under the ability's exact name:
   ```json
   { "Fire": "fire.png", "Water": "water.png", "Hauling": "hauling.png" }
   ```
3. Push. The site picks them up on its next deploy.

## How the calculator decides

- **"One Aniimo can cover several abilities"** (on by default): an Aniimo with Grass 3 + Hauling 2 counts toward both needs. Turn it off if each worker should fill only one need.
- **"Allow more than one of the same Aniimo"** (on by default): you can catch several of the same species. Turn it off to require different Aniimo.
- If no team fits under your max, the calculator shows the smallest possible team and how many slots it needs.

## Tests

With the local server running, open these pages:
- `http://localhost:8080/tests/solver.test.html`: solver unit tests.
- `http://localhost:8080/tests/data.test.html`: data sanity checks plus real-roster scenarios, with timings.

## License

The code is MIT licensed. Aniimo, its creatures, names and game icons are the property of Pawprint Studio / FunPlus and are not covered by that licence. This is an unofficial fan tool, not affiliated with or endorsed by them.
