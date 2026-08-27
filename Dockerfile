FROM ubuntu:24.04

ARG USERNAME=hluser
ARG USER_UID=10000
ARG USER_GID=10000
ARG UPSTREAM_COMMIT=405cc08b17a727ee51b0f9128918955a84439915
ARG HL_VISOR_URL=https://binaries.hyperliquid.xyz/Mainnet/hl-visor
ARG HL_VISOR_ASC_URL=https://binaries.hyperliquid.xyz/Mainnet/hl-visor.asc

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home "${USERNAME}" \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends ca-certificates curl gnupg procps python3 util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o "${USER_UID}" -g "${USER_GID}" \
        "/home/${USERNAME}/hl/data" \
        "/home/${USERNAME}/hl/file_mod_time_tracker"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

RUN set -eux; \
    curl --fail --location --retry 3 \
        "https://raw.githubusercontent.com/hyperliquid-dex/node/${UPSTREAM_COMMIT}/pub_key.asc" \
        --output pub_key.asc; \
    actual_fingerprint="$(gpg --show-keys --with-colons pub_key.asc | sed -n 's/^fpr:::::::::\([^:]*\):$/\1/p' | head -n 1)"; \
    test "${actual_fingerprint}" = "CF2C2EA3DC3E8F042A55FB6503254A9349F1820B"; \
    gpg --batch --import pub_key.asc; \
    curl --fail --location --retry 3 "${HL_VISOR_URL}" --output hl-visor; \
    curl --fail --location --retry 3 "${HL_VISOR_ASC_URL}" --output hl-visor.asc; \
    gpg --batch --verify hl-visor.asc hl-visor; \
    sha256sum hl-visor > hl-visor.sha256; \
    cat hl-visor.sha256; \
    chmod 0755 hl-visor

USER root
COPY --chown=root:root scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
COPY --chown=root:root scripts/config-init.sh /usr/local/bin/config-init.sh
COPY --chown=root:root scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chown=root:root scripts/prune-loop.sh /usr/local/bin/prune-loop.sh
COPY --chown=root:root scripts/pruner-healthcheck.sh /usr/local/bin/pruner-healthcheck.sh
COPY --chown=root:root scripts/prune.sh /usr/local/bin/prune.sh
COPY --chown=root:root scripts/render-config.sh /usr/local/bin/render-config.sh
COPY --chown=root:root scripts/verify-config.sh /usr/local/bin/verify-config.sh
RUN chmod 0755 \
        /usr/local/bin/config-init.sh \
        /usr/local/bin/container-entrypoint.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/prune-loop.sh \
        /usr/local/bin/pruner-healthcheck.sh \
        /usr/local/bin/prune.sh \
        /usr/local/bin/render-config.sh \
        /usr/local/bin/verify-config.sh

LABEL org.opencontainers.image.source="https://github.com/hyperliquid-dex/node" \
      org.opencontainers.image.revision="${UPSTREAM_COMMIT}"

ENV HOME=/home/${USERNAME} \
    HL_USER_UID=${USER_UID} \
    HL_USER_GID=${USER_GID}

EXPOSE 4001-4002

ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
CMD ["/home/hluser/hl-visor", "run-non-validator", "--replica-cmds-style", "actions-and-responses", "--disable-output-file-buffering"]
