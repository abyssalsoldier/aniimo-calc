# Aniimo Homeland Calculator

A small web tool for planning your **Homeland** in *Aniimo*. You tell it which Homeland abilities you need and how many Aniimo your Home can hold, and it works out the smallest team that covers everything.

- **Every Aniimo and form** with its elements and Homeland abilities (Fire, Water, Grass, Earth, Lightning, Ice, Wind, Dark, Light, Hauling, Artisanship, Leisure, Perfumery) and their levels (1–4).
- **Your needs:** for each ability, set a minimum level and the number of workers.
- **Best team:** the fewest Aniimo that meet every need. When two teams are the same size, the one with higher total ability levels wins. The search is exact (branch-and-bound), not a guess.
- **Prismana toggle:** Prismana forms are rare, so they're **excluded by default**. If a need can only be met by a Prismana form, or allowing Prismana would shrink your team, the calculator tells you.
- **Unobtainable entries**, such as bosses with no wild spawn, evolution or egg, are shown in the list but never used in teams.
- **"Only use Aniimo I own"**: tick the Aniimo you have in the list and plan with just those.
- Settings and your owned list are saved in your browser.

## Running it on Windows

You don't need to install anything. The server is a plain PowerShell script.

1. Get the code:
   ```
   git clone https://github.com/abyssalsoldier/aniimo-calc
   cd aniimo-calc
   ```
   Run `git pull` later to get updates.
2. Start the server on the port you want:
   - Double-click **`start.bat`**. It uses port **8080**, or `ANIIMO_PORT` if you've set it.
   - Or, from a terminal: `start.bat 5173`
   - Or call PowerShell directly: `powershell -ExecutionPolicy Bypass -File serve.ps1 -Port 5173`
3. Open `http://localhost:5173` (use your port) to check it works. Press **Ctrl+C** in the server window to stop it.

The server only listens on `127.0.0.1`, so nothing on your network can reach it except through your tunnel. It only serves the site's own files. Pass `-ListenAddress 0.0.0.0` if you want it reachable on your LAN.

### Putting it on your domain with an existing Cloudflare Tunnel

Point a public hostname on your tunnel at the local port:

- **Tunnel managed in the dashboard:** go to Cloudflare Zero Trust → Networks → Tunnels → your tunnel → **Public Hostname** → *Add a public hostname*. Enter subdomain `calc`, your domain, service type **HTTP**, and URL **`localhost:5173`**.
- **Tunnel managed with a `config.yml`:** add a rule *above* the final catch-all rule, then restart `cloudflared`:
  ```yaml
  ingress:
    - hostname: calc.yourdomain.com
      service: http://localhost:5173
    # ...your existing rules...
    - service: http_status:404
  ```

### Starting it automatically

Open Task Scheduler → *Create Basic Task* → trigger **When I log on** → action **Start a program**. For the program, choose `start.bat` in the repo folder. Put your port (e.g. `5173`) in *Add arguments*, and the repo folder in *Start in*.

## Updating the Aniimo data

The roster lives in [`data/aniimo.json`](data/aniimo.json). It's built from [metabot.gg](https://metabot.gg/en/aniimo/creatures) by:

```
powershell -ExecutionPolicy Bypass -File tools\scrape.ps1
```

Pass `-Only tromber,glacy` to refetch specific creatures into a separate file with `-OutFile`. Each entry looks like this:

```json
{ "id": "tromber-beach", "name": "Tromber", "form": "Beach Form", "prismana": false,
  "elements": ["Wind", "Water"], "abilities": { "Wind": 3, "Water": 2 } }
```

If you spot a wrong ability or level, fix the entry directly and open a pull request, or [open an issue](https://github.com/abyssalsoldier/aniimo-calc/issues).

## How the calculator decides

- **"One Aniimo can cover several abilities"** (on by default): an Aniimo with Grass 3 + Hauling 2 counts toward both needs. Turn it off if each worker should fill only one need.
- **"Allow more than one of the same Aniimo"** (on by default): you can catch several of the same species. Turn it off to require different Aniimo.
- If no team fits under your max, the calculator shows the smallest possible team and how many slots it needs.

## Tests

With the server running, open these pages:
- `http://localhost:8080/tests/solver.test.html`: solver unit tests.
- `http://localhost:8080/tests/data.test.html`: data sanity checks plus real-roster scenarios, with timings.

## License

MIT. Aniimo and its creatures belong to their respective owners. This is an unofficial fan tool.
