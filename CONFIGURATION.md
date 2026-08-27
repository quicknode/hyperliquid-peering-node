# Configuration reference

The only required operator-created file is `.env`. Docker Compose mounts it read-only into the one-shot `config` container, which renders and validates four runtime files in the private `hl-config` volume. The node mounts that volume read-only and copies the files into the locations expected by `hl-visor`.

Never commit `.env`. It contains the customer's public node address and Quicknode-provided peer addresses. Those values are operationally sensitive even though they are not passwords. Set mode `0600`; the values are not copied into the node or pruner container environments.

## Peer settings

| Variable                      | Accepted value                                         | Purpose                                                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PEER_MODE`                   | `quicknode` or `public`                                | Selects the isolated customer path or public development bootstrap. Use `quicknode` in production.                                                                                                               |
| `PUBLIC_IP`                   | Globally routable IPv4 address                         | Advertises the customer's node address. Quicknode also allowlists this address.                                                                                                                                  |
| `QUICKNODE_ROOT_NODE_IPS`     | Exactly three distinct, comma-separated IPv4 addresses | Supplies the Quicknode Mainnet root addresses provided during activation. The renderer stores each as `{"Ip":"address"}`, matching the upstream root schema.                                                    |
| `QUICKNODE_RESERVED_PEER_IPS` | Distinct, comma-separated IPv4 addresses               | Supplies the reserved peer addresses provided during activation using the upstream string-list schema. The documented example uses three.                                                                        |
| `QUICKNODE_ACTIVE_ROOTS`      | `all`, `1`, `2`, or `3`                                | Uses all roots in normal operation. Numeric choices exist only to isolate a root during acceptance testing.                                                                                                      |
| `TRY_NEW_PEERS`               | `false` in Quicknode mode                              | Prevents public peer discovery from masking a Quicknode peering failure. Public development mode deliberately overrides this to `true`.                                                                          |
| `SPLIT_CLIENT_BLOCKS`         | `true`                                                 | Requests the split data path needed for raw mempool delivery. It must also be enabled through the upstream peer path.                                                                                            |
| `ENABLE_PRIORITY_ORDERING`    | `true` or `false`                                      | Renders `node_gossip_priority_config.json` with the selected boolean. The optional onchain gossip-auction setting is independent of raw mempool availability and defaults to `false`.                              |

The renderer rejects documentation ranges, private/non-global addresses, duplicates, missing reserved peers in isolated Quicknode mode, and any attempt to enable public discovery in Quicknode mode. It never prints an address.

Priority ordering does not enable raw mempool delivery or prove a transaction's eventual execution order. Keep it disabled unless Quicknode instructs you to enable it.

## Node output settings

| Variable            | Default | Purpose                                                                                                                                                                      |
| ------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NODE_OUTPUT_FLAGS` | Empty   | Adds an allowlisted, whitespace-separated set of optional Hyperliquid file-output flags to the fixed non-validator command. Quote the value when enabling more than one flag. |

The fixed command already includes `--replica-cmds-style actions-and-responses` and `--disable-output-file-buffering`. Full responses increase record size, and disabling buffering flushes every line immediately at the cost of more disk I/O. During catch-up or with additional outputs enabled, monitor CPU, memory, and disk pressure; insufficient memory can result in an OOM termination. Raw mempool delivery is controlled separately by `SPLIT_CLIENT_BLOCKS=true` in the gossip configuration.

The repository accepts these optional flags:

| Flag                                     | Purpose and output                                                                                                                                       |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--write-trades`                         | Writes trades to `data/node_trades/hourly/`.                                                                                                             |
| `--write-fills`                          | Writes API-format fills to `data/node_fills/hourly/` and TWAP statuses to `data/node_twap_statuses/`. It overrides `--write-trades` when both are set.    |
| `--write-order-statuses`                 | Writes every L1 order status to `data/node_order_statuses/hourly/`. This can produce substantial data.                                                   |
| `--write-raw-book-diffs`                 | Writes every L1 order difference to `data/node_raw_book_diffs/hourly/`. This can produce substantial data.                                              |
| `--write-hip3-oracle-updates`            | Writes HIP-3 deployer oracle update actions to `data/hip3_oracle_updates/hourly/`.                                                                        |
| `--write-misc-events`                    | Writes miscellaneous event data to `data/misc_events/hourly/`.                                                                                           |
| `--write-system-and-core-writer-actions` | Writes CoreWriter and HyperCore-to-HyperEVM transfer data to `data/system_and_core_writer_actions/hourly/`.                                               |
| `--batch-by-block`                       | Changes the optional output schema to one block per line: `{local_time, block_time, block_number, events}`.                                               |
| `--stream-with-block-info`               | Writes events as they are processed while using the block-metadata schema.                                                                                |

For example:

```dotenv
NODE_OUTPUT_FLAGS="--write-fills --write-order-statuses"
```

Unknown or duplicate flags fail the configuration gate. Review the [official Hyperliquid flag reference](https://github.com/hyperliquid-dex/node#flags) and the corresponding data schemas before enabling outputs.

`verify.sh` checks `replica_cmds` and `mempool_txs`, while the pruner manages only `replica_cmds`, `mempool_txs`, and `node_logs`. Neither covers optional outputs. Add a freshness check, storage budget, and retention policy for every optional directory you enable.

### Capacity planning for optional outputs

There is no universal host specification for all flag combinations. Each selected output adds file writes, retained data, and work for downstream consumers. Hyperliquid identifies order statuses and raw book differences as potentially substantial outputs; the other feeds also vary with network activity.

Before production, run the exact flag combination you need and measure:

- Byte growth for each enabled directory during catch-up and normal operation
- CPU and memory use, including Docker's `.State.OOMKilled` value after an unexpected exit
- Disk latency, throughput, and free-space trend
- Downstream processing throughput and consumer lag
- The effect of the intended retention or archival job while the node is writing

As a planning aid, you can convert each measured byte delta into a daily rate, multiply each feed by its retention days, and add the retained default outputs and restart state. With the default `MIN_FREE_PERCENT=20`, dividing that total by `0.80` gives a directional minimum-capacity estimate before additional operational headroom. Treat the result as workload-specific, and do not derive a production daily rate from a short catch-up sample.

Provision enough capacity for the measured retention window while preserving the `MIN_FREE_PERCENT` safety margin. Add per-directory freshness monitoring because the bundled health and readiness checks cover only the default replica and mempool paths. Add explicit retention or archival automation because the bundled pruner intentionally excludes optional directories.

`docker compose up -d --build` automates build, validation, and startup. It does not choose a safe output set, derive production capacity, or operate downstream data pipelines.

The node copies generated configuration into its persistent home when the container starts. After changing a node setting in `.env`, apply it with `docker compose up -d --build --force-recreate` or, when the included systemd unit owns the stack, `systemctl reload hyperliquid-peering-node.service`. Wait for replay and rerun both verification commands. Recreating only the pruner is sufficient for retention-only changes.

## Health and readiness

| Variable               | Default | Purpose                                                                                                                                                   |
| ---------------------- | ------: | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REQUIRE_MEMPOOL`      |  `true` | Requires recently modified `mempool_txs` output as part of readiness for the Quicknode customer path. Public-peer development can override it to `false`. |
| `OUTPUT_STALE_MINUTES` |     `5` | Maximum output age accepted by health and readiness checks after initial output has appeared.                                                             |
| `MIN_FREE_PERCENT`     |    `20` | Marks the node unhealthy and fails readiness when filesystem free space drops below this percentage.                                                      |

Docker health means the process, persisted state, disk headroom, and, after the first replica file appears, fresh output are present. `scripts/verify.sh` is the stronger readiness test: it additionally requires advancing applied heights, fresh replica files, and optionally fresh mempool files.

## Retention and pruning

| Variable                    |   Default | Purpose                                                                                                     |
| --------------------------- | --------: | ----------------------------------------------------------------------------------------------------------- |
| `PRUNE_ENABLED`             |   `false` | Enables scheduled pruner execution. `false` keeps the scheduler healthy but performs no scans or deletions. |
| `PRUNE_MODE`                | `dry-run` | `dry-run` reports eligible files; `apply` deletes them. It has an effect only when pruning is enabled.      |
| `PRUNE_START_DELAY_SECONDS` |     `900` | Allows the node to create and mark its data volume before the first scheduled run.                          |
| `PRUNE_INTERVAL_SECONDS`    |    `1800` | Delay between runs; values below 60 seconds are rejected.                                                   |
| `MEMPOOL_RETENTION_MINUTES` |     `360` | Retention for files strictly beneath `data/mempool_txs`.                                                    |
| `BLOCK_RETENTION_MINUTES`   |    `1440` | Retention for files strictly beneath `data/replica_cmds`.                                                   |
| `LOG_RETENTION_MINUTES`     |    `1440` | Retention for files strictly beneath `data/node_logs`.                                                      |

The script refuses an unmarked volume, an empty data root, or any data root other than `/home/hluser/hl/data`. Its allowlist contains only the three output directories above; it never traverses `hyperliquid_data`, where restart state is stored. Directory age is not used: only regular files older than their class's retention are candidates.

When pruning is enabled, container health permits the configured startup delay plus five minutes for the first success. It then becomes unhealthy if the last successful dry-run or apply run is older than the interval plus five minutes.

The public example intentionally does not enable deletion because retention is a product/data requirement, not a universal safe value. A reviewed customer `.env` can set `PRUNE_ENABLED=true` and `PRUNE_MODE=apply`; the same `docker compose up -d --build` command then starts the automatic apply schedule.

Raw mempool output is the dominant storage risk. Quicknode has observed approximately 1.1 TB/day, although actual volume varies with network activity. At that rate, a 2,340 GiB disk has only about two days of gross capacity before safety headroom. Operators must approve retention, monitor free space, and confirm that downstream consumers have processed files before enabling deletion; the example values are not a universal policy.

## Generated runtime files

| File                               | Meaning                                                                                      |
| ---------------------------------- | -------------------------------------------------------------------------------------------- |
| `visor.json`                       | Selects Hyperliquid Mainnet.                                                                 |
| `override_gossip_config.json`      | Defines roots, reserved peers, discovery behavior, Mainnet, and split-client-block behavior. |
| `override_public_ip_address`       | Advertises the customer's allowlisted public IPv4 address.                                   |
| `node_gossip_priority_config.json` | Enables or disables the optional priority-ordering behavior.                                 |

The files live in the Docker-managed `hl-config` volume rather than the source tree. The full node home lives in `hl-home`, preserving both emitted data and restart-required state across container replacement.

## Compose services and volumes

| Component   | Role                                                                                                                                                     |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config`    | One-shot gate that mounts `.env` read-only, renders the four runtime files, validates them without printing addresses, and exits before the node starts. |
| `node`      | Runs the Mainnet visor and child node as UID/GID `10000`, publishes TCP `4001`-`4002`, and mounts both persistent volumes.                               |
| `pruner`    | Runs the disabled, dry-run, or apply scheduler against the `hl-home` volume as UID/GID `10000`.                                                          |
| `hl-config` | Private generated configuration. It is mounted read-only by the node and does not expose peer values through container environment metadata.             |
| `hl-home`   | Complete node home containing emitted data and `hyperliquid_data` restart state. Preserve it across container replacement.                               |

## Node command and image choices

The image runs:

```text
hl-visor run-non-validator --replica-cmds-style actions-and-responses --disable-output-file-buffering
```

`actions-and-responses` retains executed block actions plus responses; it is not a prebuilt order book. Disabling output buffering makes freshness checks and downstream tailing timely while increasing disk I/O. The Dockerfile pins the upstream source commit used to obtain the signing key, verifies its fingerprint, and verifies the mutable Mainnet visor download with that key before installing it.

The node runs as UID/GID 10000 after a root entrypoint installs configuration with restrictive permissions. TCP `4001`-`4002` are the only published ports. A 120-second Compose stop allowance gives the visor time to exit, but the current binary may still require Docker to force-stop it. Preserve the complete `hl-home` volume, wait for checkpoint replay, and rerun readiness checks after restart.
