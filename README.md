# Hyperliquid Peering Node

Run a Hyperliquid Mainnet non-validating node with Docker Compose and [Quicknode Peering](https://www.quicknode.com/hyperliquid-peering?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node). The deployment writes full block output and raw pending transactions to a persistent Docker volume, verifies that data is fresh, and includes safe retention and host-restart tooling.

This repository does not build an order book, indexer, database, or trading strategy. Peering supplies raw files to a node you operate. Use Quicknode's [managed Hyperliquid datasets](https://www.quicknode.com/docs/hyperliquid/datasets?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node) when your application needs filtered streams or purpose-built L2/L4 order-book data.

This repository focuses on Quicknode Peering configuration and the deployment, verification, persistence, and retention controls around the node. Use the [official Hyperliquid node repository](https://github.com/hyperliquid-dex/node) as the source of truth for upstream node requirements, releases, and behavior, and review it before deploying or upgrading the node.

For the narrated walkthrough of these steps, see [Run a Hyperliquid Node with Quicknode Peering](https://www.quicknode.com/guides/hyperliquid/run-non-validating-node-with-quicknode-peering?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node).

## What the deployment includes

- A build that verifies Hyperliquid's signed Mainnet visor
- A one-command Docker Compose startup path
- Quicknode-only peer configuration with public discovery disabled
- Persistent node data and restart state
- Full block output using `actions-and-responses`
- Raw mempool output using split client blocks
- Allowlisted optional file-output flags for trades, fills, order statuses, and other datasets
- Readiness and peer-isolation checks that fail closed
- A disabled-by-default, allowlisted pruning scheduler
- An optional systemd unit for boot and service lifecycle management

## Prerequisites

You need:

- A Quicknode account with Hyperliquid Peering activated
- The Quicknode Mainnet root and reserved peer addresses supplied during provisioning
- A stable public IPv4 address submitted to Quicknode for allowlisting
- Ubuntu 24.04 with Docker Engine, Buildx, and the Compose plugin
- Inbound TCP ports `4001` and `4002`, plus outbound network access

Hyperliquid's upstream base specification lists 16 vCPUs, 128 GB RAM, and a 500 GB SSD, but 500 GB is not a retention target. Quicknode has observed approximately 1.1 TB/day of raw mempool output, with higher short intervals. Enabled outputs, retention, catch-up load, downstream processes, and local compilation all change the requirement. Benchmark the complete workload before production.

## Quick start

Clone the repository on the allowlisted Ubuntu host:

```bash
git clone https://github.com/quicknode/hyperliquid-peering-node.git
cd hyperliquid-peering-node
cp .env.example .env
chmod 600 .env
```

Edit `.env` and replace every documentation address with the values supplied for your deployment. Keep:

```dotenv
PEER_MODE=quicknode
QUICKNODE_ACTIVE_ROOTS=all
TRY_NEW_PEERS=false
SPLIT_CLIENT_BLOCKS=true
ENABLE_PRIORITY_ORDERING=false
NODE_OUTPUT_FLAGS=""
REQUIRE_MEMPOOL=true
PRUNE_ENABLED=false
PRUNE_MODE=dry-run
```

The peer addresses are operationally sensitive even though they are not passwords. Never commit `.env`, paste its contents into an issue, or print the rendered peer configuration in logs.

The repository maps the supplied root addresses to `QUICKNODE_ROOT_NODE_IPS` and reserved peer addresses to `QUICKNODE_RESERVED_PEER_IPS`, matching the two fields in the upstream gossip configuration. Do not substitute one list for the other.

`ENABLE_PRIORITY_ORDERING=false` renders `node_gossip_priority_config.json` as `{"enabled": false}`. This optional onchain gossip-auction setting is independent of raw mempool delivery, which remains randomly ordered by default. Keep the default unless Quicknode instructs you to enable it.

## Choose optional node output files

The image always runs `hl-visor run-non-validator` with `--replica-cmds-style actions-and-responses` and `--disable-output-file-buffering`. The first flag retains block actions plus responses, while the second flushes each line immediately. This supplies timely full-block records but increases record size and disk-write frequency. Catch-up and additional outputs can also increase CPU and memory pressure; an undersized host can have the node terminated by the Linux OOM killer. `SPLIT_CLIENT_BLOCKS=true` controls raw mempool delivery separately.

Check current resource use and whether Docker recorded an out-of-memory termination:

```bash
docker stats --no-stream "$(docker compose ps -q node)"
docker inspect --format '{{.State.OOMKilled}}' "$(docker compose ps -q node)"
```

Set the quoted, whitespace-separated `NODE_OUTPUT_FLAGS` value for additional purpose-specific files:

```dotenv
NODE_OUTPUT_FLAGS="--write-fills --write-order-statuses"
```

Available output selections are:

| Data needed                              | Flag                                     | Additional output                                        |
| ---------------------------------------- | ---------------------------------------- | -------------------------------------------------------- |
| Trades                                   | `--write-trades`                         | `data/node_trades/hourly/`                               |
| Fills and TWAP statuses                  | `--write-fills`                          | `data/node_fills/hourly/` and `data/node_twap_statuses/` |
| Every order lifecycle status             | `--write-order-statuses`                 | `data/node_order_statuses/hourly/`                       |
| Every raw L1 order book difference       | `--write-raw-book-diffs`                 | `data/node_raw_book_diffs/hourly/`                       |
| HIP-3 deployer oracle updates            | `--write-hip3-oracle-updates`            | `data/hip3_oracle_updates/hourly/`                       |
| Miscellaneous events                     | `--write-misc-events`                    | `data/misc_events/hourly/`                               |
| CoreWriter and HyperCore transfer events | `--write-system-and-core-writer-actions` | `data/system_and_core_writer_actions/hourly/`            |

You can also change how these optional events are written:

| Format needed                 | Flag                       | Behavior                                                              |
| ----------------------------- | -------------------------- | --------------------------------------------------------------------- |
| One record per block          | `--batch-by-block`         | Batches events into `{local_time, block_time, block_number, events}`. |
| Stream events with block data | `--stream-with-block-info` | Writes events as processed while including the same block metadata.   |

`--write-fills` overrides `--write-trades` when both are present. Unknown or duplicate values fail the configuration gate. See [CONFIGURATION.md](CONFIGURATION.md#node-output-settings) and the [official Hyperliquid flag reference](https://github.com/hyperliquid-dex/node#flags) for the complete schemas.

### Plan capacity for enabled outputs

There is no single host specification for every flag combination. Each selected output adds file writes, storage, retention work, and downstream processing. Order statuses and raw book differences can produce substantial data, while the volume of the other feeds varies with network activity.

Before production:

1. Enable the exact output combination your application needs.
2. Measure CPU, memory, disk latency, and consumer lag during catch-up and normal operation.
3. Capture per-directory byte growth over a representative interval.
4. Size storage for the retention window while preserving the configured `MIN_FREE_PERCENT` safety margin.
5. Add freshness monitoring and a reviewed retention or archival policy for every optional directory.

`verify.sh` does not check optional output directories, and the included pruner does not delete them.

For a rough view of storage growth, you can capture exact byte counts twice, separated by a representative measurement interval:

```bash
docker compose exec -T node sh -c '
for output_dir in \
  node_trades node_fills node_twap_statuses node_order_statuses \
  node_raw_book_diffs hip3_oracle_updates misc_events \
  system_and_core_writer_actions
do
  path="/home/hluser/hl/data/${output_dir}"
  [ ! -d "${path}" ] || du -sb "${path}"
done
'
```

Comparing the two snapshots can help estimate growth for the exact workload. As a planning aid, you can convert the difference into a daily rate, multiply each feed by its retention days, and add the retained default outputs and restart state. If you use the default 20% free-space threshold, dividing that total by `0.80` gives a directional minimum-capacity estimate before additional operational headroom.

Treat the result as directional rather than a universal requirement. Short catch-up samples are particularly unsuitable for daily projections because catch-up and network activity can materially change output volume.

Build and start the complete stack:

```bash
docker compose up -d --build
```

This is the direct Compose lifecycle option. Complete the readiness checks below, then install the [systemd wrapper](#manage-the-stack-with-systemd) if the host should manage the project as a boot service. Once installed, use `systemctl` for full-stack start, stop, and reload operations; the unit delegates to this same Compose project.

This command:

1. Builds the image and verifies the Hyperliquid signing key and Mainnet visor signature.
2. Renders configuration into a private Docker volume.
3. Refuses placeholder, private, duplicate, or incomplete peer values.
4. Starts the node only after the configuration gate succeeds.
5. Starts the pruning scheduler with deletion disabled by default.

The command automates deployment, not production operations. It does not select the outputs your application needs, size storage for them, monitor optional directories, set their retention, or confirm that downstream consumers keep up.

## Wait for data readiness

Compose startup means the processes launched. It does not mean the node is synchronized. A new node must receive and replay a checkpoint, a state snapshot used to bootstrap or catch up, before its applied height and output files become fresh.

Run:

```bash
./scripts/verify.sh
```

It is normal for the command to return non-zero during initial synchronization. Repeat it until it confirms an advancing applied height, fresh full-block and raw-mempool output, healthy processes, and sufficient disk headroom.

Then verify that the observed network paths are restricted to the configured Quicknode peers:

```bash
./scripts/verify-peer-isolation.py --since 30m
```

The isolation check reads the configuration copy used by the current node container, inspects its established gossip sockets, and searches the requested recent-log window for unexpected activity. It reports counts only. It fails if public discovery is enabled, no approved current or recent peer connection exists, an unexpected target appears, or candidate-peer discovery occurs. A three-root deployment may keep one approved socket open in steady state; recent socket churn across all three roots is not required.

## Find the data

The `hl-home` named volume persists the complete `/home/hluser/hl` tree. Important paths inside the node container are:

| Path                                 | Contents                                                           |
| ------------------------------------ | ------------------------------------------------------------------ |
| `/home/hluser/hl/data/replica_cmds/` | Executed block actions and responses                               |
| `/home/hluser/hl/data/mempool_txs/`  | Raw pending signed transaction inputs                              |
| `/home/hluser/hl/data/node_logs/`    | Node-generated logs                                                |
| `/home/hluser/hl/hyperliquid_data/`  | Restart and synchronization state; never pruned by this repository |

Raw mempool records are pending inputs, not confirmed execution results. They can fail or never enter a committed block. Neither output directory is a prebuilt order book.

## Configure retention safely

Pruning is disabled in `.env.example`. The example retention windows are six hours for raw mempool files and 24 hours for block output and node logs, but they are not a universal production policy. Choose them from your disk capacity and downstream-consumer requirements.

The pruner can only inspect regular files below these allowlisted directories:

- `data/mempool_txs`
- `data/replica_cmds`
- `data/node_logs`

It refuses an unexpected or unmarked volume and never traverses `hyperliquid_data`.

First enable scheduled dry-run mode in `.env`:

```dotenv
PRUNE_ENABLED=true
PRUNE_MODE=dry-run
```

Recreate only the pruning service and inspect its candidates:

```bash
docker compose up -d --force-recreate pruner
docker compose logs --no-color pruner
```

After confirming the paths, ages, and downstream processing state, change `PRUNE_MODE=apply` and recreate the pruner again. Keep disk monitoring active; successful pruning does not guarantee that the selected capacity is adequate.

For an operator-approved one-off apply run:

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/prune.sh pruner --apply
```

Run `./scripts/verify.sh` again after any retention change.

## Manage the stack with systemd

Docker's `restart: unless-stopped` policy restores containers after a Docker daemon restart. Install the optional unit when you also want the complete Compose application managed as a host service.

The unit expects the repository at `/opt/hyperliquid-peering-node`:

```bash
sudo systemd-analyze verify systemd/hyperliquid-peering-node.service
sudo install -m 0644 systemd/hyperliquid-peering-node.service \
  /etc/systemd/system/hyperliquid-peering-node.service
sudo systemctl daemon-reload
sudo systemctl enable --now hyperliquid-peering-node.service
```

After a service start or host reboot, wait for checkpoint replay and run both verification commands again.

After changing a node setting in `.env`, reload the systemd service so the configuration gate reruns and the node copies the new generated files before it starts:

```bash
sudo systemctl reload hyperliquid-peering-node.service
```

Reload force-recreates the Compose containers. Allow up to the documented 120-second node stop window, then wait for checkpoint replay and rerun both verification commands. Retention-only changes can continue to use the pruner-only recreation command above.

The current signed Mainnet visor can remain running until Compose's 120-second stop allowance expires, after which Docker may report forced exit `137`. The systemd unit allows time for this behavior. Preserve the full `hl-home` volume, then wait for checkpoint replay and rerun both verification commands after a restart.

## Monitor the deployment

Monitor at least:

- `docker compose ps` state, health, and restart counts
- Applied block-height progress in node logs
- Fresh files under `replica_cmds` and `mempool_txs`
- Free disk space and write throughput
- CPU, memory, network, and disk I/O
- Downstream consumer lag before files become eligible for pruning
- Peer disconnects and the time required to regain fresh output

Container health is not a synchronization guarantee. Use `verify.sh` as the data-readiness boundary and the isolation script as the Quicknode-only network boundary.

## Disruptive acceptance test

`scripts/test-unavailable-peer-path.sh` proves that the node reports a failure instead of silently falling back when the Quicknode peer path is unreachable. It rewrites host `iptables` rules, restarts the node, and stops data flow for the duration of the run.

Do not run it on a production node. It requires root and an explicit `CONFIRM_UNAVAILABLE_PEER_TEST=yes`, and it restores the firewall rules and restarts the node on exit. Reserve it for a dedicated test host.

## Troubleshooting

| Symptom                                                | Likely cause or next check                                                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| Configuration container exits non-zero                 | Replace documentation addresses, remove duplicates, and confirm every required `.env` value.                                  |
| Node cannot establish the initial peer path            | Confirm Quicknode allowlisted the advertised public IPv4 and verify TCP `4001`-`4002` through the cloud firewall.             |
| Compose is running but `verify.sh` fails               | The node may still be receiving or replaying a checkpoint. Check applied heights and wait for fresh output.                   |
| Mempool output is missing                              | Confirm `SPLIT_CLIENT_BLOCKS=true`, `REQUIRE_MEMPOOL=true`, and that the supplied upstream path supports split client blocks. |
| Isolation verification fails                           | Check that `TRY_NEW_PEERS=false`, all supplied roots are active, and no public or unexpected peer path was used.              |
| Node becomes unhealthy after previously producing data | Check stale output, peer connectivity, checkpoint activity, and disk headroom.                                                |
| Node exits or restarts unexpectedly under load          | Check `docker stats`, Docker's `.State.OOMKilled` value, and host memory pressure.                                             |
| Pruner refuses to run                                  | Confirm the expected named volume and data path exist; do not bypass its volume or directory guards.                          |
| Disk headroom is low                                   | Stop unnecessary growth, review a dry run, and apply only an approved retention policy after downstream consumers are safe.   |

## Updates and recovery

The image pins the upstream Hyperliquid repository revision used to obtain the signing key, then verifies the mutable Mainnet visor download with that key. Review upstream and repository changes before rebuilding. After an update, repeat the normal Compose build/start command, readiness check, peer-isolation check, and a restart/recovery check before treating the node as production ready.

To stop the Compose stack while preserving both named volumes:

```bash
docker compose down
```

Do not delete `hl-home` unless you intentionally accept loss of local output and restart state.

## Configuration reference

See [CONFIGURATION.md](CONFIGURATION.md) for every environment value, generated file, node flag, container, health boundary, volume, and retention control.

## Support

- [Guide: Run a Hyperliquid Node with Quicknode Peering](https://www.quicknode.com/guides/hyperliquid/run-non-validating-node-with-quicknode-peering?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node)
- [Quicknode Hyperliquid Peering](https://www.quicknode.com/hyperliquid-peering?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node)
- [Quicknode Hyperliquid documentation](https://www.quicknode.com/docs/hyperliquid?utm_source=internal&utm_campaign=github&utm_content=hyperliquid-peering-node)
- [Hyperliquid node repository](https://github.com/hyperliquid-dex/node)
- [Quicknode support](https://support.quicknode.com/)

## License

This project's original files are available under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the Hyperliquid upstream source and license.
