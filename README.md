# Transmission 4 for WD My Cloud OS5

An unofficial **Transmission 4** app for **WD My Cloud OS5**, installed from the dashboard with **Apps → Install an app manually**. It's a current BitTorrent daemon, built from the official 4.1.4 source:
- It runs as `nobody:share`, not root, and serves RPC and the web UI on port 9091.
- It can take over the settings of WD's own Transmission 3.00 app once.

The app has an On/Off switch, a **Configure** page and an Uninstall button in the dashboard. It doesn't edit other apps or system files.

Its companion, [Tailscale for WD My Cloud OS5](../../../wd-mycloud-os5-tailscale), is built the same way.

> **Unofficial.** Not made, endorsed or supported by Western Digital or the Transmission project. The app is provided as is (see [LICENSE](LICENSE)). The NAS may be your only copy of some data: read the notes below before installing.

## Supported devices

| Device | Status |
|---|---|
| My Cloud EX2 Ultra, OS 5.33.102 | Tested, in daily use |
| Other OS5 models | Untested |

Other ARM models need their own build (the model name is part of the package). The x86 models (PR2100, PR4100, DL2100, DL4100) need x86 binaries, which this repo doesn't build.

## Installing

1. **Download** the `.bin` from the [releases](../../releases) and compare its SHA256 with the one published next to it.
2. **Install:** in the dashboard, **Apps → Install an app manually**, then choose the file. The app installs switched OFF.
3. **Switch it on:** read the first-start notes below, then switch **Run App** ON.
4. **Configure:** with the app ON, its **Configure** button opens its settings page inside the dashboard.

The usual setup needs no SSH. For the rest (logs, the initial password), turn SSH on under **Settings → Network → Network Services → SSH**; the user name is `sshd`.

## First start

- **If WD's Transmission app is installed,** switch it OFF first. This app refuses to start while WD's runs.
  - On its first start it copies WD's settings, torrents and login.
  - WD's copy is left as it is, and you can uninstall WD's app afterwards.
- **Without WD's app,** the user name is `transmission` and the password is random. Set your own on the **Configure** page; until then it's in `/mnt/HD/HD_a2/.transmission4/initial-password`, readable over SSH.
- **Clients** (transgui, Transmission Remote, mobile apps) connect to `http://<nas>:9091/transmission/rpc`. The web UI is at `http://<nas>:9091/transmission/web/`.
- **Downloads** go to the `Transmission` share (`/mnt/HD/HD_a2/Transmission`), owned by `nobody:share`, so they work over SMB.
- **Incoming peers:** UPnP/NAT-PMP port forwarding is off. Forward the peer port (Transmission's settings) on your router by hand if you want incoming peers.

## The Configure page

You can change the user name, the password, the port (9091 by default) and the allowed addresses. Saving restarts Transmission, and transfers resume on their own. Only a salted hash of the password is stored, as Transmission itself does.

**Allowed addresses:** by default, private home networks (10.x, 172.16–31.x, 192.168.x) and Tailscale (100.64–127.x). A login is required as well.
- The list takes one pattern per line, with `*` as a wildcard and `[0-9]` ranges. CIDR doesn't work.
- It's kept in `/mnt/HD/HD_a2/.transmission4/allowed-networks`. If you edit that file over SSH, switch the app OFF and ON afterwards.
- A file with anything else in it is ignored as a whole, and the defaults apply.

## Updating

Install the newer `.bin` over the installed app, whether it's ON or OFF. Transmission stops cleanly and starts again, and transfers resume on their own.

WD's dashboard calls this a re-install, and installs the new package switched OFF. The app remembers whether it was ON. Once WD's installer has finished, it puts Run App back the way it was, so the page you get after "App installed" shows it ON. If the dashboard's own list still disagrees a few seconds later, the app asks WD with the same request the dashboard's switch sends. If the dashboard still shows OFF after a refresh, switch it ON yourself: that's harmless, and makes the dashboard match.

WD's "Updating" dialog sometimes never hears that the installer has finished, and waits for good. If WD recorded the install as done and the app was ON, the app hands the dialog that result. If the dialog still hangs, refresh the page.

## Uninstalling

Settings, torrents and logs are kept in `/mnt/HD/HD_a2/.transmission4/`, and your downloads are never touched. A later install picks them up again. Delete that folder over SSH to remove everything but the downloads.

## Where things are

| | |
|---|---|
| App (replaced on every upgrade) | `/mnt/HD/HD_a2/Nas_Prog/transmission4/` |
| Settings and torrents | `/mnt/HD/HD_a2/.transmission4/config/` |
| Logs (1 MB, one rotation) | `/mnt/HD/HD_a2/.transmission4/log/` |
| What the app did, in order | `log/app.log` |

## How it works

- **WD's app lifecycle** was measured on the NAS, not guessed: which script runs when, with which arguments, on install, upgrade, boot and shutdown. The results are in [docs/os5-app-lifecycle.md](docs/os5-app-lifecycle.md).
  - WD switches every app OFF on upgrade and deletes its folder.
  - So the app keeps its state and its own "should run" flag on the data volume, and restores itself.
- **The EX2 Ultra's kernel uses 32 KB memory pages.** A binary or library whose ELF segments are aligned to only 4 KB segfaults before it starts.
  - That's true of most distribution packages and many Docker images. qemu on a PC can't show it.
  - So Transmission and su-exec here are compiled as static binaries linked for 64 KB pages.
  - [tools/check-elf-alignment.sh](tools/check-elf-alignment.sh) checks any binary, and every package build runs it.
- **Security:**
  - Transmission runs as `nobody:share`, with login and allowed networks enforced at every start.
  - Upstream files are pinned by checksum, so the build refuses anything else.
  - No secrets are ever in a package. Passwords stay on the data volume.
- **The Configure page.** WD's web server runs PHP as root, so the page's small `api.php` is written as a security boundary ([common/web/app-api.php](common/web/app-api.php)):
  - The page lives only under `/apps/transmission4/`, the one place where the dashboard login is required (`CenterType: 1`). `api.php` refuses to work from anywhere else.
  - Requests from other websites are refused: each one needs a custom header and a matching `Origin`.
  - Every value is checked in PHP, and again by the app's `ctl.sh`, which does the actual work. Values reach it on stdin, never on a command line.
  - The page shows no secrets, and the password is stored only as its salted hash.
  - Passwords travel like the dashboard's own login does: encrypted when you open the dashboard over Tailscale or its HTTPS port, readable on the network over plain HTTP.

## Building from source

You need Linux or WSL2 with Docker. Run everything from the repository root.

```sh
tools/register-arm-emulation.sh   # once per boot: lets Docker run ARM containers
transmission4/build.sh            # compiles Transmission on emulated ARM (slow)
tests/run-all.sh                  # stub package, simulations, syntax checks, ShellCheck
tests/web-preview.sh              # the Configure page on http://localhost:8080, with a stub daemon
```

- **`dist/`** gets the `.bin` with its `.sha256` and a list of its contents.
- **Pinning:** the build refuses upstream files whose checksums differ from the pinned ones, in `transmission4/upstream.env`.
- **The build image:** an Alpine v3.24 container, whose exact package set is pinned in `transmission4/packages.lock`.
- **New Transmission release:** edit `transmission4/upstream.env`, with the SHA256 from GitHub's release and the SHA512 from Alpine's recipe.
- **Security fixes in the libraries built into Transmission** (OpenSSL, curl, musl and others): `transmission4/build.sh --update-lock`, then review the diff of `packages.lock`.
- **Versions** are `<upstream>-<revision>`; bump the revision in `apkg.rc` for any change to the package.
- **Icon:** edit `transmission4/icon.svg`, then run `tools/render-icons.sh`.

`tests/run-all.sh` drives the app through WD's measured script sequences in a BusyBox container, with a stub daemon:
- install, upgrades while ON, reboots, takeover of WD's settings, refusals, uninstall
- a NAS with and without WD's Transmission app

It also serves the Configure page with PHP 7.4, as on the NAS, and calls its `api.php` as the page does. That covers the request guards, bad values, and each change end to end. Finally it checks the PHP and JavaScript syntax and runs ShellCheck.

## License

The scripts in this repository are under the MIT License ([LICENSE](LICENSE)).

The package also contains third-party software under its own licenses. Its `licenses/` folder has a `README.txt` that lists every component and its license. The Transmission binary as built here is distributed under GPL-3.0. Its complete corresponding source is the pinned official tarball, the Alpine packages listed in `transmission4/packages.lock`, and this repository.
