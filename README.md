# FPP Finder

A small desktop app (Windows + macOS, Electron) that lists the devices on your local network and
**highlights Falcon Player (FPP) controllers** — with version, mode, platform and installed plugins.
Works fully offline. **Read-only: it never writes to or changes any device.**

## What it shows
Per device: IP, MAC, hostname, vendor (bundled IEEE OUI table, ~40k entries), open common ports, first-seen /
last-seen, and a **NEW** badge for devices that first appeared in the latest scan. Sorted by most recently seen.
FPP devices get a green row with version, mode (player/remote/bridge), platform (BeagleBone / Raspberry Pi),
hostname, status, plugin list, an **Open web UI** button and **Copy IP**. Toggles: *FPP only*, *Pin FPP on top*,
*Show offline*, text filter, auto-rescan interval (15 s – 5 min), manual **Rescan**. History is kept in the
app's user-data folder (30 days).

## How it finds things
1. **Interfaces** – every active, non-loopback IPv4 interface, including link-local (169.254.x.x) links.
2. **TCP sweep** – connects to port 80 on each host of each interface's own subnet (≤ /22 fully; for bigger
   subnets such as a /16 link-local network only the host's own /24 plus already-known hosts, never the whole /16).
   A refused connection also proves a host is alive; the attempt makes the OS ARP-resolve neighbours.
3. **ARP table** (`arp -an` on macOS/Linux, `arp -a` on Windows) → MAC addresses → vendor.
4. **mDNS/Bonjour** queries per interface (`_fppd._udp`, `_http._tcp`, `_wled._tcp`, …) and `fpp.local` /
   previously seen `*.local` names resolved through the OS resolver (this is how a link-local FPP is found).
5. **FPP MultiSync** UDP port 32320: passively listens for FPP ping packets (nothing is sent).
6. **FPP probe** – read-only `GET`s with short timeouts on `/api/fppd/version` (decides FPP-or-not),
   `/api/fppd/status`, `/api/fppd/multiSyncSystems`, `/api/system/info`, `/api/plugin`, `/api/network/interface`.

## What it does NOT do
- It never scans outside the host's own subnets, never sends anything but TCP SYNs, mDNS queries and HTTP GETs,
  and never POSTs/PUTs or changes a device.
- No ICMP ping (needs raw sockets/admin): TCP + ARP is used instead. Devices that drop TCP *and* are not in the ARP
  cache won't be seen. A host seen only in the ARP cache is badged `ARP` (may be stale).
- Link-local hosts are found via ARP, mDNS or `<name>.local`; an unknown link-local host that is hidden from all three
  won't be discovered.
- **macOS caveat:** on some macOS setups the ARP table is hidden from the app (Local Network privacy). The app then
  shows a warning; allow it under *System Settings → Privacy & Security → Local Network*. Even without ARP, FPP devices
  are still found through `.local` names / mDNS and report their own MAC through the FPP API.

## Run
```bash
npm install
npm start
```
Headless scan (no GUI): `npm run scan` (`-- --json`, `-- --seed 169.254.9.67`).

## Test
```bash
npm test      # unit tests: ARP (macOS/Windows/Linux fixtures), OUI, subnet math, FPP classification, multisync packets
```

## Build
```bash
npm run dist:mac    # dist/FPP Finder-<ver>-<arch>.dmg and -mac.zip (unsigned)
npm run dist:win    # dist/FPP Finder-<ver>-win.zip (portable; builds from macOS without Wine)
```
Unsigned builds: on macOS right-click → Open the first time; Windows SmartScreen shows "More info → Run anyway".
`.github/workflows/build.yml` builds both on `windows-latest` and `macos-latest` and uploads artifacts
(Windows additionally gets an NSIS installer in CI).

## Publish later (not done yet — nothing has been pushed)
```bash
cd fpp-finder
git init && git add . && git commit -m "FPP Finder"
gh repo create <you>/fpp-finder --public --source . --push     # or create the repo on github.com and `git remote add origin … && git push -u origin main`
git tag v1.0.0 && git push origin v1.0.0                       # tag push triggers the CI build
```
The workflow assumes `fpp-finder/` is the repository root. If you instead push the whole project folder, move
`.github/` to the repo root and add `working-directory: fpp-finder` to the steps.

## Dev hooks (env vars)
`FPP_FINDER_DUMP=/path/out.json` writes the first scan to JSON; `FPP_FINDER_EXIT=1` quits after it;
`FPP_FINDER_SHOT=/path/shot.png` also saves a window screenshot; `FPP_FINDER_SEEDS=ip1,ip2` adds extra hosts to probe.

Data: OUI table from the IEEE MA-L registry (`npm run build:oui` regenerates it from a downloaded `oui.csv`).
