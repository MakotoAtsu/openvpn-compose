# openvpn-compose

[繁體中文](README.zh-TW.md)

An OpenVPN server you deploy with one command: clone, fill in `.env`, `docker compose up -d`.

It creates its own certificates and one ready-to-import `.ovpn` profile per client. Everything environment-specific (address, port, network, DNS, client names) lives in `.env`, so moving servers, changing IPs, adding devices or replacing a router means editing a setting and running `up` again.

This repository only runs OpenVPN. DNS records and cloud firewall rules are yours to set; see [What this does not do](#what-this-does-not-do).

## Requirements

- A Linux host with Docker Engine and Compose v2, `/dev/net/tun`, and iptables support in the kernel.
- A reachable UDP port (default 1194) on that host.

Use `sudo` with the commands below unless your user is in the `docker` group.

## Quick start

```sh
git clone <this repository> openvpn-compose && cd openvpn-compose
cp .env.example .env
$EDITOR .env                  # set VPN_HOST at least
docker compose up -d
```

The first run builds the image, creates the CA, the server certificate and a profile for every name in `VPN_CLIENTS`, then starts the server. Profiles are written to `data/clients/<name>.ovpn`.

Copy a profile to the device that will connect and import it there. The files are root-owned and mode 600 (a profile contains that client's private key), so read them with `sudo`:

```sh
# from your own machine
ssh user@server 'sudo cat openvpn-compose/data/clients/vpn-client.ovpn' > vpn-client.ovpn
```

## Configuration

Set these in `.env` (see `.env.example`). Values are plain text, no quotes.

| Variable | Default | Meaning |
|---|---|---|
| `VPN_HOST` | none, required | Address clients connect to: a DNS name or an IP. Written into every profile as the `remote` line. |
| `VPN_PORT` | `1194` | UDP port published on the host. The server itself always listens on 1194 inside the container. |
| `VPN_SUBNET` | `172.16.88.0/24` | Private network handed out to connected clients (prefix length 8 to 29). Must not overlap any network on either end of the tunnel: the server's own networks, Docker's networks, the client's LAN. |
| `VPN_DNS` | `1.1.1.1,1.0.0.1` | DNS servers pushed to clients, comma separated. Empty pushes none. |
| `VPN_REDIRECT_GATEWAY` | `true` | `true`: clients send all their traffic through the VPN and the server becomes their exit. `false`: only traffic for the VPN network goes through the tunnel and the client's own internet access is unchanged. |
| `VPN_CLIENTS` | `vpn-client` | One certificate and profile per name, comma separated. Letters, digits, `-` and `_` only. Use one name per device: two devices cannot be connected with the same certificate at once, and the name is what appears in the server log. |
| `VPN_CERT_DAYS` | `3650` | Validity in days for newly issued certificates. Anything that would expire after 2037 is rejected, because older 32-bit clients (many routers) can mishandle later dates. |

## Everyday tasks

**Apply a changed setting.** Edit `.env`, then `docker compose up -d`.
- `VPN_SUBNET`, `VPN_DNS`, `VPN_REDIRECT_GATEWAY`: the server restarts with the new values; profiles are unaffected.
- `VPN_HOST`, `VPN_PORT`: profiles are rewritten. Re-import them on the devices (or, if `VPN_HOST` is a DNS name that you simply repointed, nothing changes for clients).

**Add a device.** Add a name to `VPN_CLIENTS`, run `docker compose up -d`, fetch `data/clients/<name>.ovpn`. Existing clients are untouched.

**Replace a device.** Give the new device a new name, as above. The old device's certificate keeps working until you revoke it (next item).

**Revoke access.** There is no revocation list. To lock out every issued certificate, stop the server, delete `data/`, run `docker compose up -d`, and re-import the new profiles on every device. Removing a name from `VPN_CLIENTS` only stops generating it; its certificate stays valid.

**Update.** `git pull && docker compose up -d --build`.

**Logs.** `docker compose logs -f openvpn`. Look for `Initialization Sequence Completed` after a start and the client name when a device connects.

**Server certificate renewal.** `init` reissues the server certificate when it is invalid or expires within 30 days, but the running server only reads it at start, so run `docker compose restart openvpn` if `docker compose logs init` shows it was reissued. With the default validity this is a once-in-a-decade event.

## Where things live

```
data/                  created at first run, never committed
  ca/                  ca.crt, ca.key          the CA; ca.key is only needed to issue certificates
  server/              ca.crt, server.crt,     the only directory the server container sees
                       server.key, tls-crypt.key   (read-only)
  clients/             <name>.crt, <name>.key, <name>.ovpn
```

`data/` holds private keys and is git-ignored. It is also kept out of the image build. Back it up: losing the CA means every device needs a new profile. `git clean -fdx` deletes it.

Because the CA key is not needed to run the server, you can move `data/ca/ca.key` somewhere safe once your profiles are made. The server keeps working; you only need the key back to issue new certificates, and `init` will tell you when it is missing.

### Reusing an existing PKI

To keep devices working across a rebuild or move, copy the old files into the same layout before the first `up`:

```
data/ca/ca.crt  data/ca/ca.key
data/clients/<name>.crt  data/clients/<name>.key      # <name> must be listed in VPN_CLIENTS
data/server/tls-crypt.key
```

`init` reuses what exists and only issues what is missing, normally just the server certificate. Devices keep working because their certificates are unchanged. Their profile files are regenerated; if the originals came from this repository and `VPN_HOST` and `VPN_PORT` are unchanged, the new files are byte-identical, so nothing needs re-importing.

## What this does not do

- **DNS.** If `VPN_HOST` is a name, creating its record is up to you. An IP address works too.
- **Firewalling.** Allow inbound UDP on `VPN_PORT` in your cloud security group or host firewall, and restrict the source addresses there if you know where clients connect from. Do not rely on a host firewall such as `ufw`: Docker publishes the port through its own iptables rules, which bypass `ufw`.
- **IPv6, TCP, multiple servers, per-client revocation.** The server is IPv4 over UDP.

## How it works

`compose.yaml` runs two services from one image. `init` (`init-pki.sh`) runs once per `up`, creates whatever is missing under `data/` and exits. `openvpn` (`entrypoint.sh`) renders `server.conf` from the environment, sets up forwarding and NAT inside its own network namespace, and runs OpenVPN as an unprivileged user. It needs only `NET_ADMIN` and `/dev/net/tun`, not `--privileged` and not host networking.

## Troubleshooting

- **Client never connects.** Check that UDP `VPN_PORT` is open to the client, that `VPN_HOST` resolves to this server, and that the profile is the current one.
- **Connects, but no internet.** Check that `VPN_REDIRECT_GATEWAY` is `true`, that the server can reach the internet itself, and that `VPN_SUBNET` doesn't overlap a network the client already uses.
- **`init` stops with an error.** The message names the setting or file. The usual causes are a bad `.env` value, or files in `data/` left half-created.
- **`net.ipv4.ip_forward is off`.** Your Docker setup refused the `sysctls` entry in `compose.yaml`; enable forwarding on the host.
