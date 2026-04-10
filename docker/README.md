# Docker Daemon Configuration

This directory contains a `daemon.json` that tells the host Docker
daemon to allocate all new networks from `10.10.0.0/16` (in `/24`
slices) instead of the default `172.16.0.0/12` / `192.168.0.0/16`
pools.

This is useful on sites where the `172.x.x.x` range conflicts with
existing corporate routes, VPNs, or other services.

## What it does

With this config in place:

* Docker's default bridge (`docker0`) and every `docker network create`
  (including Compose-created networks) will allocate addresses from
  `10.10.0.0/16`.
* Each new network receives a `/24` slice, so you get 256 networks
  before exhausting the pool.
* No container or network ends up on `172.x.x.x`.

Note: the `dgx-stack` Compose file additionally pins its own network
to `10.10.0.0/24` explicitly, so the stack works correctly regardless
of whether this daemon config is installed.

## Installing

**This change requires root and restarts the Docker daemon**, which
briefly stops all running containers on the host. The recommended
path is to let `setup.sh` offer to install it on your behalf — the
script will diff any existing `/etc/docker/daemon.json`, back it up,
merge the address-pool setting, and restart `docker.service`.

To install manually:

```bash
sudo mkdir -p /etc/docker
sudo cp docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

If `/etc/docker/daemon.json` already exists, merge the
`default-address-pools` field into it rather than overwriting the
whole file.

## Verifying

After installation and restart:

```bash
# docker0 should be in 10.10.x.x
ip -4 addr show docker0

# Any new network should also be allocated from 10.10.0.0/16
docker network create test-pool
docker network inspect test-pool | grep Subnet
docker network rm test-pool
```
