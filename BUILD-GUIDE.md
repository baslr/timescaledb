# TimescaleDB Build & Setup Guide (Debian/Ubuntu, PostgreSQL 17)

## 1. Install Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake git \
  postgresql-17 \
  postgresql-server-dev-17 \
  postgresql-client-17 \
  libicu-dev \
  tzdata-legacy
```

**Packages explained:**

| Package | Purpose |
|---------|---------|
| `postgresql-17` | Server (includes `initdb`, `pg_regress`) |
| `postgresql-server-dev-17` | Headers + `pg_config` for compilation |
| `libicu-dev` | Unicode headers (`unicode/ucol.h`) for VectorAgg |
| `tzdata-legacy` | Legacy timezone links (`US/Pacific` etc.) for tests |

## 2. Clone Repository / Checkout Branch

```bash
git clone https://github.com/baslr/timescaledb.git
cd timescaledb
git checkout flat_dictionary
```

## 3. Build (Debug with Assertions)

```bash
# One-time: create build directory
./bootstrap -DCMAKE_BUILD_TYPE=Debug -DASSERTIONS=ON

# Compile
cd build
make -j"$(nproc)"

# Install (into PG directories)
sudo make install
```

**If CMake doesn't pick up new source files** (e.g. after adding `.c` files):
```bash
cd build && cmake . && make -j"$(nproc)"
```

## 4. Configure PostgreSQL

TimescaleDB must be preloaded as a shared library **before** the extension can be
created. Without this step, `CREATE EXTENSION` fails with `must be preloaded`.

```bash
# Add to config
echo "shared_preload_libraries = 'timescaledb'" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

# Restart PostgreSQL — required for the library to load
sudo pg_ctlcluster 17 main restart
```

## 5. Activate Extension in a Database

The extension must be created **once per database**:

```bash
sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
```

This registers the TimescaleDB functions, the `tsdb.*` namespace for
`CREATE TABLE ... WITH (tsdb.hypertable, ...)`, and the internal catalog tables
(e.g. `_timescaledb_catalog.compression_settings`).

Verify:
```bash
sudo -u postgres psql -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';"
```

Expected output:
```
 extversion
------------
 2.27.2
```

## 6. Verify flat_dictionary Works

```bash
sudo -u postgres psql <<'SQL'
CREATE TABLE test_fd(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.orderby='time',
    tsdb.segmentby='device',
    tsdb.compress_algorithm='tags flat_dictionary'
);

-- Verify: algorithm must show {tags=8}
SELECT relid::regclass, segmentby, orderby, algorithm
FROM _timescaledb_catalog.compression_settings
WHERE relid = 'test_fd'::regclass;

DROP TABLE test_fd CASCADE;
SQL
```

Expected output:
```
  relid  | segmentby | orderby | algorithm
---------+-----------+---------+-----------
 test_fd | {device}  | {time}  | {tags=8}
```

## 7. Run Tests

From the repo root:

```bash
cd build

# Single test (temporary PG instance):
TESTS=compress_flat_dict_pushdown make installcheck-t

# Regression suite:
TESTS="compress_flat_dict_pushdown compress_unordered_sort compress_sort_transform \
       compression compression_sorted_merge transparent_decompression" \
  make installcheck-t
```

**Note:** `installcheck-t` starts its own temporary PG instance on port 55432. To test against the running local instance, use `installchecklocal-t` (requires passwordless `psql` connection as current user).

## 8. After Code Changes: Rebuild Cycle

```bash
cd build
make -j"$(nproc)"          # incremental compile
sudo make install          # install into PG
sudo pg_ctlcluster 17 main restart   # reload extension
```

For test-only changes (`.sql`/`.out` files):
```bash
TESTS=compress_flat_dict_pushdown make installcheck-t
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `pg_config: not found` | `sudo apt install postgresql-server-dev-17` |
| `unicode/ucol.h: No such file` | `sudo apt install libicu-dev` |
| `initdb: not found` | `sudo apt install postgresql-17` |
| `TimeZone "US/Pacific" invalid` | `sudo apt install tzdata-legacy` |
| `shared_preload_libraries` error | Check path in `postgresql.conf`, then `sudo pg_ctlcluster 17 main restart` |
| `-Werror` on unused functions | Add `pg_attribute_unused()` to the function, or remove it |

---

## Alternative: Container (Podman/Docker)

Instead of installing locally, everything can run in a container. The repo
contains a multi-stage `Dockerfile` + `compose.yaml`.

### Start

```bash
cd timescaledb
podman compose up -d
```

First time builds the image (compiles TimescaleDB inside the container).
After that it starts in seconds.

### Connect

```bash
psql -h localhost -p 5444 -U postgres -d postgres
# Password: postgres
```

### Status / Logs

```bash
podman compose ps
podman compose logs -f timescaledb-dev
```

### Stop / Remove

```bash
# Stop (data persists in volume):
podman compose down

# Stop + delete volume (everything gone):
podman compose down -v
```

### Rebuild After Code Changes

**Important:** You must use `--no-cache` to force a full rebuild. Without it,
Podman reuses cached layers and your code changes won't be included in the image.

```bash
podman compose down -v
podman rmi localhost/timescaledb_timescaledb-dev:latest
podman compose build --no-cache
podman compose up -d
```

Or in one step:
```bash
podman compose up -d --build
```

### Configuration (compose.yaml)

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_PASSWORD` | `postgres` | Password |
| `POSTGRES_DB` | `postgres` | Database (created on first start) |
| Port | `5444` | Host port (internal 5432) |

### How It Works

1. **Builder stage**: Based on `postgres:17-bookworm`, installs build tools,
   compiles TimescaleDB, places artifacts in `/install/`
2. **Runtime stage**: Fresh `postgres:17-bookworm`, copies only the compiled
   `.so` + `.sql` + `.control` files, configures `shared_preload_libraries`,
   creates the extension automatically on first start

### .pgpass for Passwordless Connections

So `psql` doesn't prompt for a password every time:

```bash
# ~/.pgpass — one line per instance
# Format: hostname:port:database:username:password
cat >> ~/.pgpass << 'EOF'
localhost:5432:*:postgres:your_prod_password
localhost:5444:*:postgres:postgres
EOF
chmod 600 ~/.pgpass
```

---

## Further Reading

- **[USAGE-flat-dictionary.md](USAGE-flat-dictionary.md)** — Create tables with flat_dictionary, compression policy, stream data
- **[HOST-SESSION-flat-dict-cache.md](HOST-SESSION-flat-dict-cache.md)** — Technical details on the cache code and test workflow
