# clk-nixinit

Clickwork's Ubuntu server provisioner. One wrapper, one cloud-init file, and a
module per component — each module is a standalone installer that also runs on
its own, without the wrapper.

Replaces `old_sources/clk-24.04`, `old_sources/clk-proxy` and
`old_sources/clk-mariaDBkp`. `old_sources/` is left untouched as reference.

## Layout

```
clk-nixinit.sh          the wrapper: role selection, module sequencing
cloud-init.yaml         first-boot bootstrap for a fresh KVM instance
lib/common.sh           shared library, sourced by the wrapper and every module
modules/<name>/
    make-<name>.sh      the module entrypoint (customize.sh for customize,
                        no make- prefix -- it isn't building anything)
    confs/              config files copied into /etc/...
    blocks/             vhost templates rendered with envsubst
    snips/              config fragments
    scripts/            CLI tools installed to /usr/sbin
```

Three modules go by a shortened id, and their entrypoint follows that id, not
the folder's old full name: `firewall` is `modules/csf/make-csf.sh`,
`phpmyadmin` is `modules/pma/make-pma.sh`, `pureftpd` is
`modules/pftpd/make-pftpd.sh`. `mariadbkp` keeps its folder name but its
entrypoint is `make-mdbkp.sh`. `./clk-nixinit.sh -l` prints every module's
actual script name.

## Running it

Interactive, on a Hyper-V VM you built by hand:

```sh
sudo ./clk-nixinit.sh
```

Non-interactive, from cloud-init or a script:

```sh
sudo ./clk-nixinit.sh -r lamp -f vps1.example.ro -p 8.5,7.4 -y --cleanup
```

It reboots when finished by default; pass `--no-reboot` to skip that. The
checkout is left in place unless `--cleanup` is given.

Every flag also reads a `CLK_` environment variable, so cloud-init can set them
all without touching the command line. `./clk-nixinit.sh -h` prints the list.

One module on its own, against an already provisioned box:

```sh
sudo modules/mariadbkp/make-mdbkp.sh
sudo modules/php/make-php.sh 8.5,8.4
sudo modules/nginx/make-nginx.sh proxy
```

`./clk-nixinit.sh -l` lists the modules.

## Roles

| Role | What it builds |
|---|---|
| `lamp` | apache on `127.0.0.1:9080`, mariadb, php-fpm, phpMyAdmin, pure-ftpd, behind an nginx TLS edge |
| `lemp` | nginx serving php-fpm directly, mariadb, phpMyAdmin, pure-ftpd |
| `proxy` | reverse proxy: HAProxy on 443 in front of nginx on 9443 over proxy_protocol |
| `core` | customization, firewall and outbound mail, nothing else — **the default when no role is given** |

`customize`, `csf` (the firewall module) and `postfix` are mandatory and run
first for every role — including `core` and `proxy` — so alerts (lfd,
cron, this installer's own log) always have somewhere to go, regardless of
what else the box does. MariaDB always brings `mariadbkp` with it; every
hosting role always gets `entld`.

## Module dependency order

The wrapper runs `customize`, `csf` and `postfix`, then the rest in dependency
order, not alphabetically:

- `lamp` — apache → mariadb → php → pma → wildcard → nginx(edge) → certbot(hostname-cert) → pftpd → hosting
- `lemp` — mariadb → php → nginx(web) → certbot(hostname-cert) → pma → wildcard → pftpd → hosting
- `proxy` — haproxy → nginx(proxy) → certbot(pkg-only) → proxytools
- `core` — nothing beyond the three mandatory modules

php has to land before nginx in `lemp`, because the nginx admin snippet is
rendered against the default fpm pool. apache has to land before php in `lamp`,
because php wires itself into apache.

`postfix` never needs a certificate of its own on any role: it only ever
submits mail (`inet_interfaces = localhost`, nothing external ever connects
to it), so outbound TLS is opportunistic client-side (`smtp_tls_security_level
= may`) — that only validates the *remote* server's certificate, against the
system CA bundle, with nothing local to request from certbot. That's what
makes it safe to run before certbot, or on a role that never installs certbot
at all, like `core`.

`certbot` itself runs in one of two modes. `hostname-cert` (LAMP/LEMP)
installs the package and also requests a certificate for the server's own
hostname, because pure-ftpd consumes it there. `pkg-only` (the `proxy` role)
installs the package and the renewal hook but requests
nothing — there is no vhost to request one against until `entld.ngx` builds a
real one for an actual proxied domain and requests its certificate right
after, the same way `entld` already does for LAMP/LEMP.

Running a module on its own respects this too — it reads what it needs from the
install profile and skips what is not there.

## State

| Path | What it holds |
|---|---|
| `/root/salt` | every generated credential, plaintext, legacy format — day-2 tools grep it |
| `/etc/clickwork/nixinit.conf` | the non-secret install profile: role, admin user, php versions, ports |
| `/var/log/clickwork/nixinit.log` | full command output of every module run |

`/root/salt` keeps the exact wording the old scripts used, so
`grep -oP "mariaDB password is:\s+\K\w+"` still works.

The profile is what makes a module runnable on its own, and what lets one
`lampstart` serve a LAMP box, a LEMP box and a proxy — it tests and reloads only
what the profile says is installed.

## Day-2 tools

| Tool | Role | What it does |
|---|---|---|
| `entld` | lamp, lemp | provision a domain: db, ftp user, vhost, certificate, webroot |
| `distld` | lamp, lemp | tear the same domain down again |
| `passtld` | lamp, lemp | roll an existing domain's shared db + ftp password (`-p` to type one) |
| `ngxentld` | lamp, lemp | re-enable an existing nginx site |
| `entld.ngx` | proxy | nginx server block + certificate for a proxied domain |
| `entld.hpx` | proxy | HAProxy SNI entry and backend file |
| `entld.proxy` | proxy | add a domain: dispatches to `entld.hpx` and `entld.ngx` |
| `distld.proxy` | proxy | remove a domain again, local or remote |
| `lampstart` | all | test then reload the whole stack — route every config change through it |
| `clkcsf` | all | open ports, allow/ignore IPs, restart csf/lfd |
| `krnlcln` | all | list and purge old kernel packages |
| `mdbkp` | wherever mariadb is | nightly per-database dump, driven by cron.daily |

`entld`, `distld` and `passtld` all gate on the same domain check — a real
hostname, then a count of what the domain actually has on the box (vhosts,
webroot, certificate, database user, ftp row). They differ only in the verdict:
`entld` refuses if anything already exists, `distld` refuses only if nothing
does (a stale database after a failed teardown is exactly what it is for), and
`passtld` refuses if there are no credentials to roll. `passtld` decides before
generating, so a mistyped domain never leaves an orphan pair in `/root/salt`.

On a proxy, HAProxy owns `:443` and routes on SNI without decrypting. A domain
in `localdomains.file` goes to local nginx on `9443` over proxy_protocol; one
in `remotedomains.map` is passed through to the mapped backend with TLS intact;
anything else is rejected outright. `entld.proxy -l` registers both the apex
and its `www` — the ACL matches whole lines, so without the `www` entry the
redirect vhost `entld.ngx` builds would be rejected before reaching nginx.

Both modes ask the same question — where does this domain's traffic go — and
differ only in what they do with the answer:

- **`-l` local** — the backend goes into the nginx server block's `proxy_pass`,
  since nginx terminates TLS here and forwards on.
- **`-r` remote** — the backend goes into a HAProxy backend for 443, *and*
  nginx gets a port-80-only forward block to the same host. HAProxy binds only
  `:443`, so without that block http for a remote domain would hit nginx's
  blackhole and die; with it, the remote server gets the request and decides
  what to do (redirect, ACME, whatever). No certificate is issued for it —
  nothing is terminated locally, so there is nothing to hold one for.

Generated backends live one per file in `/etc/haproxy/conf.d`, loaded through a
second `-f` on the unit (`EXTRAOPTS` in `/etc/default/haproxy`), never written
into `haproxy.cfg`. That keeps the shipped config untouched and lets
`distld.proxy` drop a backend by deleting a file — and it only deletes one once
no other mapped domain still points at it. Both tools test the config before
reloading, against the same file set systemd loads.

`mariadbkp` keeps the original `mdbkp.sh` convention of installing itself once
(copying itself into `/etc/clickwork/mariaDBkp/mdbkp`), after which every later
invocation of the *installed* copy runs a backup instead of reinstalling.
Unlike the original it does not delete its own source directory — it now
lives inside this checkout, not a standalone one-off clone, so that's no
longer its job. Deleting the whole checkout, source and all, is the wrapper's
`--cleanup` flag.

## Target release

Ubuntu **26.04 and newer**. For 24.04 use the old scripts under `old_sources/`
instead — nginx there is 1.24, which predates the `http2 on;` directive these
configs rely on.

## Package sources

- **nginx, apache, everything else** — the Ubuntu archive, no third party repo
- **php** — `ppa:ondrej/php`, the only PPA still in use, because it carries
  multiple concurrent php-fpm versions (7.4 alongside 8.x) that the archive
  does not. With no `-p`/`CLK_PHP`, the version is `latest`, resolved against
  the repo *after* the PPA is added rather than hardcoded — so it never goes
  stale. The interactive prompt offers the newest three of the 8 branch plus
  the last of the 7 branch, in any combination; that menu list is the one
  hardcoded thing, and going stale there only costs a hint, never a wrong
  install
- **mariadb** — MariaDB's own repo via `mariadb_repo_setup`, pinned to the
  **11.4** LTS series (override with `CLK_MARIADB_VERSION`)

## Fixed conventions

- ssh on port **2282**
- apache backend on **127.0.0.1:9080** only, never exposed
- pure-ftpd passive range **40001–40128**
- the highest installed php version is the default fpm pool, the rest are opt-in
  per vhost through the `a2.phost` snippet
- the admin username follows the release codename (`resolute` on 26.04) on KVM
  and on Hyper-V alike — on KVM it is created, on Hyper-V it already exists and
  is adopted

## Verification

The scripts are ShellCheck clean. After editing any of them:

```sh
shellcheck -x <file>
shfmt -d <file>
```

`.shellcheckrc` sets `source-path=SCRIPTDIR` so `-x` resolves `lib/common.sh`
from each module's own directory.

## Not yet ported

`old_sources/clk-24.04/make-mass.sh` — the SundayMass weekly maintenance timer.
It is self-contained and unrelated to provisioning, so it was left where it is.
