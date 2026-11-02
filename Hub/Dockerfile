# The hub image. Build context is Hub/ (docker build Hub). Builds for linux/arm64 and linux/amd64
# (both base images are multi-platform indexes, pinned by index digest).

# rust:1.93.1-slim-bookworm
FROM rust@sha256:5b9332190bb3b9ece73b810cd1f1e9f06343b294ce184bcb067f0747d7d333ea AS chef
# cargo-chef splits dependency compilation from the hub's own, so a source-only change reuses the
# dependency layer.
RUN cargo install cargo-chef --locked --version 0.1.78
WORKDIR /src

FROM chef AS planner
# rust-toolchain.toml is deliberately not copied: the base image already is Rust 1.93.1, and the
# file would make cargo try to install components over the network.
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
# The recipe changes only when a manifest or the lockfile does, which keeps the cook layer cached.
COPY --from=planner /src/recipe.json recipe.json
RUN cargo chef cook --release --locked --recipe-path recipe.json
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo fetch --locked
RUN cargo build --release --locked --offline --bin b4hub

# debian:bookworm-slim
FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS rdsca
# The Amazon RDS CA bundle is fetched at build time so the image has no network dependency at run
# time, and the deploy's attestation covers it.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /rds-global-bundle.pem

# debian:bookworm-slim
FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runtime
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 b4hub \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin b4hub
COPY --from=builder --chmod=0555 /src/target/release/b4hub /usr/local/bin/b4hub
COPY --from=rdsca --chmod=0444 /rds-global-bundle.pem /etc/ssl/certs/rds-global-bundle.pem
USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=5s --timeout=4s --start-period=5s --retries=3 CMD curl --fail --silent http://127.0.0.1:8080/readyz
ENTRYPOINT ["/usr/local/bin/b4hub"]
CMD ["serve"]
