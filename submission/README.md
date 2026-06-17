# Redis Cluster Lifecycle Tool

A CLI tool that wraps Ansible to provision, operate, and perform a rolling upgrade of a 6-node Redis Cluster (3 masters + 3 replicas) with zero client-visible downtime and verified data integrity.

## Prerequisites

- **Container runtime**: Docker Engine or Podman (either works — the tool auto-detects whichever is on your PATH)
- **Ansible 2.14+**: `ansible-playbook` must be on your PATH
- **Python 3**: required by Ansible on the control node
- **SSH client**: `ssh-keygen` to generate the keypair used for control-node → container auth

> `redis-tool` checks for all of the above as the very first thing it does on any command, and prints exactly what's missing and how to install it before exiting — it never tries to install anything without you running it yourself.

### Install Docker

See https://docs.docker.com/engine/install/

### Install Podman

See https://podman.io/docs/installation

### Install Ansible 2.14+

```bash
pip install --upgrade ansible
```

## Quick Start

### Step 1 — Generate the SSH keypair and build the containers
```bash
chmod +x redis-tool setup.sh
```

# Docker
```bash
cd infra
docker compose -f compose.yml build
docker compose -f compose.yml up -d

# OR Podman
podman build -t redis-cluster-node:latest -f Containerfile .
podman-compose -f compose.yml up -d
```

`setup.sh` only handles file permissions — it doesn't build or start anything for you, so the compose step above is still required. Confirm all six nodes came up before continuing:

```bash
docker ps | grep redis-node
```

### Step 2 — Run the tool

```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
./redis-tool status
./redis-tool data seed --keys 1000
./redis-tool data verify
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
./redis-tool verify --full
```

## Infrastructure

6 Ubuntu 22.04 containers, each running only `sshd` — Redis is installed and configured entirely by Ansible, not baked into the image.

| Container    | IP         | SSH port (host) |
|--------------|------------|------------------|
| redis-node-1 | 10.10.0.11 | 2221             |
| redis-node-2 | 10.10.0.12 | 2222             |
| redis-node-3 | 10.10.0.13 | 2223             |
| redis-node-4 | 10.10.0.14 | 2224             |
| redis-node-5 | 10.10.0.15 | 2225             |
| redis-node-6 | 10.10.0.16 | 2226             |

All six sit on a static bridge network (`10.10.0.0/24`, defined in `infra/compose.yml`) so the Ansible inventory can use fixed IPs. Auth is SSH key-based only — `PasswordAuthentication no` is set in the image's `sshd_config`. Ansible reaches each node through its host-mapped SSH port (`ansible_host=127.0.0.1`, `ansible_port=222x`); Redis itself binds and gossips on the internal `10.10.0.x` address (`cluster_ip` in the inventory). Those are two separate addressing paths for two separate purposes.

## Project Structure

```
submission/
├── README.md
├── redis-tool                  ← Bash CLI entrypoint
├── setup.sh                    ← permission fixups (chmod on redis-tool / SSH key)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.ini           ← 6 nodes + 2 extra_nodes used by scale-out
│   ├── playbooks/
│   │   ├── data_seed.yml
│   │   ├── data_verify.yml
│   │   ├── provision.yml       ← installs Redis, forms the cluster
│   │   ├── rollback.yml
│   │   ├── scale_in.yml
│   │   ├── scale_out.yml
│   │   ├── status.yml
│   │   ├── upgrade.yml         ← the rolling upgrade, replica-then-master
│   │   └── verify.yml          ← 5-check full verification
│   └── roles/redis/
│       ├── defaults/main.yml
│       ├── handlers/main.yml
│       ├── tasks/main.yml      ← download → compile → install → configure → start
│       └── templates/redis.conf.j2
├── infra/
│   ├── Containerfile           ← Ubuntu 22.04 + sshd (Dockerfile-compatible)
│   ├── authorized_keys
│   ├── compose.yml
│   ├── redis_cluster_key
│   └── redis_cluster_key.pub
├── logs/                       ← one JSON-line log per command, per day
│   ├── data_seed_<date>.log
│   ├── data_verify_<date>.log
│   ├── provision_<date>.log
│   ├── rollback_<date>.log
│   ├── status_<date>.log
│   ├── upgrade_<date>.log
│   └── verify_<date>.log
└── output/                     ← captured terminal output from real runs
    ├── data_seed_output.txt
    ├── data_verify_output.txt
    ├── idempotency_output.txt
    ├── provision_output.txt
    ├── status_output.txt
    ├── upgrade_output.txt
    └── verify_output.txt
```

## Rolling Upgrade Strategy

To guarantee zero client-visible downtime, `upgrade.yml` runs in this exact order:

1. **Pre-flight checks** — confirms `cluster_state:ok`, pings all six nodes individually, checks the current Redis version actually differs from `--target-version` (exits cleanly if not — see Idempotency), and runs a `data verify` pass to capture the pre-upgrade baseline.
2. **Upgrade replicas first (nodes 4, 5, 6, one at a time)** — replicas don't serve client traffic, so each one can be stopped, recompiled at the target version, restarted, and resynced with zero risk. Cluster state is confirmed `ok` after each node before moving to the next.
3. **Upgrade masters via `CLUSTER FAILOVER` (nodes 1, 2, 3, one at a time)**:
   - Find the master's replica and issue `CLUSTER FAILOVER` on it — since that replica was upgraded in step 2, the new master is already on the target version the moment it takes over.
   - Wait for the old master's role to flip to `slave`.
   - Stop it, install the target version, restart it, and let it rejoin as a replica of the node that just replaced it.
   - Confirm `cluster_state:ok` before moving to the next master.
4. **Post-upgrade verification** — full `data verify` (must still come back 1000/1000) plus a version check across all six nodes, ending in `UPGRADE COMPLETE — all nodes on v7.2.6, data integrity verified, cluster: ok`.

Progress is printed after every node: `[N/6] Upgraded <role> <ip> — cluster: ok`. At no point does the cluster drop below 3 live masters owning all 16384 slots — the only "in transition" window is the few seconds of each `CLUSTER FAILOVER`, which Redis Cluster clients absorb via `MOVED`/`ASK` redirection rather than a hard disconnect. If any task fails, the playbook stops immediately on that node/step rather than continuing — there's no automatic rollback by default.

## Idempotency

- `provision` checks for an existing `redis-server` binary on each node before downloading/compiling anything. Re-running it against an already-provisioned cluster skips the build entirely and only reapplies config.
- `upgrade` compares the cluster's current version against `--target-version` before doing anything. If they already match, it prints a message and exits cleanly instead of running the playbook:
  ```
  Cluster is already running Redis 7.2.6 — nothing to do.
  UPGRADE SKIPPED — all nodes already on v7.2.6
  ```

To see this for yourself, run `provision` again once the cluster is already on the target version and capture the output:

```bash
./redis-tool provision --version 7.2.6 --masters 3 --replicas-per-master 1 2>&1 | tee output/idempotency_output.txt
```

You'll see every "Download Redis source" / "Extract Redis source" / "Compile Redis" task report `skipping` for all six nodes, since the role's first task finds `redis-server` already installed and short-circuits the rest of the build.

## Stretch Goals Implemented

- **Scale out** — `./redis-tool scale --add-nodes 2` starts two new containers, provisions Redis on them, joins one as a master and one as its replica via `redis-cli --cluster add-node`, then rebalances slots across all masters.
- **Scale in** — `./redis-tool scale --remove-node <node-id>` migrates slots off the target master, removes it and its replica from the cluster, and tears down their containers. Takes a Redis cluster node ID (from `status` / `cluster nodes`), not a container name.

  Scale-in needs an extra node to remove, so the easiest way to exercise it is to scale out first and then immediately scale that new node back in:

  1. Make sure the base 6-node cluster is already provisioned and healthy (`./redis-tool status`).
  2. Scale out so you have a node to remove (`node-7` and `node-8`):
     ```bash
     ./redis-tool scale --add-nodes 2
     ```
  3. Confirm `node-7` joined the cluster and get its node ID:
     ```bash
     docker exec redis-node-1 redis-cli -h 10.10.0.11 -p 6379 cluster nodes | grep "10.10.0.17"
     ```
     Copy the first column — that's the node ID.
  4. Test scale in with that node ID:
     ```bash
     ./redis-tool scale --remove-node <node-id-from-above>
     ```
  5. Verify it's gone and the cluster is healthy:
     ```bash
     docker exec redis-node-1 redis-cli -h 10.10.0.11 -p 6379 cluster nodes
     docker exec redis-node-1 redis-cli -h 10.10.0.11 -p 6379 cluster info | grep cluster_state
     ```
     You should see only the original 6 nodes and `cluster_state:ok`. If there's no "Node is not empty" error and the deletion completes cleanly, scale-in is working as expected.

- **Rollback** — `./redis-tool rollback --target-version 7.0.15` stops the cluster, wipes data and cluster state files on every node, reinstalls the target version, and re-forms the cluster from scratch. It's a fast path back to a known-good binary version, not a data-preserving undo of the upgrade.
- **Structured logging** — every command appends a JSON line (timestamp, command, status, message) to `logs/<command>_<date>.log`. For an example of inspecting these logs in practice, see the Idempotency section above.

## Assumptions & Trade-offs

- **Redis is compiled from source on every node**, not installed from APT, because the project requires an exact patch version (`7.0.15` → `7.2.6`) and Ubuntu 22.04's repos don't carry arbitrary historical Redis releases.
- **Redis runs as a backgrounded process (`nohup redis-server ... &`)**, not a systemd service — these containers run `sshd` as PID 1 with no init system to hand the process to. Against real VMs this would instead be a proper unit file managed by Ansible's `service` module.
- **`cluster-announce-ip` is explicitly set to each node's internal `10.10.0.x` address**, separate from the `ansible_host`/`ansible_port` Ansible uses over SSH. Without the override, nodes would gossip `127.0.0.1` to each other and the cluster would never form.
- **The cluster is formed with `redis-cli --cluster create --cluster-replicas 1`**, letting Redis's own slot-balancing logic pick master/replica pairing rather than hand-assigning it.
- **No Redis auth (`requirepass`/ACLs)** — the cluster lives entirely on an isolated bridge network with no external exposure, so this was treated as out of scope for the exercise.

## Known Limitations

- Redis doesn't survive a container *restart* (as opposed to recreation) — it's a background process, not a managed service, so the running instance is lost. Re-run `provision` after restarting containers.
- A from-source rolling upgrade across six nodes is slow, since the masters phase also waits out failover settling and replication catch-up on top of the compile time at every step. Pre-building a binary once and distributing it with `copy`/`synchronize` instead of compiling on each node would be the obvious next optimization.
- No automatic rollback if `upgrade` fails mid-sequence — by design, not oversight. The playbook stops on the failing node/step and leaves the cluster exactly where it failed so a human can inspect it; `rollback` exists for after-the-fact recovery, with the data-loss caveat above.
- `redis-tool` doesn't manage the base six containers' lifecycle — they must already be up via `docker compose`/`podman-compose` before any command is run. It does manage the two extra containers created by `scale --add-nodes`.
