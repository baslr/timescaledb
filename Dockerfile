# Multi-stage build: compile TimescaleDB, then copy into clean PG runtime
# Usage: podman compose up -d
#
# Pin PG_VERSION to major + distro. Patches roll in on rebuild.
# Update when you want a new PostgreSQL major.

ARG PG_VERSION=17-trixie

# ==============================================================================
# Stage 1: Builder — uses the same postgres image to guarantee matching libs
# ==============================================================================
FROM docker.io/library/postgres:${PG_VERSION} AS builder

RUN apt update && apt install -y --no-install-recommends \
    build-essential cmake git ca-certificates \
    postgresql-server-dev-17 \
    libicu-dev \
    libkrb5-dev \
    && rm -rf /var/lib/apt/lists/*

# pg_config is already on PATH from the postgres base image

COPY . /src
WORKDIR /src

RUN ./bootstrap \
      -DCMAKE_BUILD_TYPE=Debug \
      -DASSERTIONS=ON \
      -DREGRESS_CHECKS=OFF \
      -DAPACHE_ONLY=OFF \
    && cd build \
    && make -j"$(nproc)" \
    && make DESTDIR=/install install

# ==============================================================================
# Stage 2: Runtime — clean PostgreSQL with TimescaleDB installed
# ==============================================================================
ARG PG_VERSION
FROM docker.io/library/postgres:${PG_VERSION}

# Copy compiled extension from builder
COPY --from=builder /install/usr/lib/postgresql/ /usr/lib/postgresql/
COPY --from=builder /install/usr/share/postgresql/ /usr/share/postgresql/

# Preload timescaledb (entrypoint picks this up)
RUN echo "shared_preload_libraries = 'timescaledb'" >> /usr/share/postgresql/postgresql.conf.sample

# Init script: create extension on first start
RUN echo "CREATE EXTENSION IF NOT EXISTS timescaledb;" \
    > /docker-entrypoint-initdb.d/001-timescaledb.sql

EXPOSE 5432
