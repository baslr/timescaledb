# TimescaleDB Build & Setup Guide (Debian/Ubuntu, PostgreSQL 17)

## 1. Voraussetzungen installieren

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

**Pakete im Detail:**

| Paket | Wozu |
|-------|------|
| `postgresql-17` | Server (inkl. `initdb`, `pg_regress`) |
| `postgresql-server-dev-17` | Header + `pg_config` zum Kompilieren |
| `libicu-dev` | Unicode-Header (`unicode/ucol.h`) für VectorAgg |
| `tzdata-legacy` | Legacy-Timezone-Links (`US/Pacific` etc.) für Tests |

## 2. Repository klonen / Branch auschecken

```bash
git clone https://github.com/baslr/timescaledb.git
cd timescaledb
git checkout flat_dictionary
```

## 3. Build (Debug mit Assertions)

```bash
# Einmalig: Build-Verzeichnis erzeugen
./bootstrap -DCMAKE_BUILD_TYPE=Debug -DASSERTIONS=ON

# Kompilieren
cd build
make -j"$(nproc)"

# Installieren (in die PG-Verzeichnisse)
sudo make install
```

**Falls CMake die Quellliste nicht erkennt** (z.B. nach neuen `.c`-Dateien):
```bash
cd build && cmake . && make -j"$(nproc)"
```

## 4. PostgreSQL konfigurieren

TimescaleDB muss als Shared Library vorgeladen werden, **bevor** die Extension
erstellt werden kann. Ohne diesen Schritt schlägt `CREATE EXTENSION` mit
`must be preloaded` fehl.

```bash
# Konfiguration ergänzen
echo "shared_preload_libraries = 'timescaledb'" | sudo tee -a /etc/postgresql/17/main/postgresql.conf

# PostgreSQL (neu)starten — nötig, damit die Library geladen wird
sudo pg_ctlcluster 17 main restart
```

## 5. Extension in einer Datenbank aktivieren

Die Extension muss **pro Datenbank** einmalig erstellt werden:

```bash
sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
```

Damit werden die TimescaleDB-Funktionen, der `tsdb.*`-Namespace für
`CREATE TABLE ... WITH (tsdb.hypertable, ...)` und die internen Katalog-Tabellen
(z.B. `_timescaledb_catalog.compression_settings`) angelegt.

Prüfen:
```bash
sudo -u postgres psql -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';"
```

Erwartete Ausgabe:
```
 extversion
------------
 2.27.2
```

## 6. Testen, ob flat_dictionary funktioniert

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

-- Prüfen: algorithm muss {tags=8} zeigen
SELECT relid::regclass, segmentby, orderby, algorithm
FROM _timescaledb_catalog.compression_settings
WHERE relid = 'test_fd'::regclass;

DROP TABLE test_fd CASCADE;
SQL
```

Erwartete Ausgabe:
```
  relid  | segmentby | orderby | algorithm
---------+-----------+---------+-----------
 test_fd | {device}  | {time}  | {tags=8}
```

## 7. Tests ausführen

Aus dem Repo-Root:

```bash
cd build

# Einzelner Test (temporäre PG-Instanz):
TESTS=compress_flat_dict_pushdown make installcheck-t

# Regressionssuite:
TESTS="compress_flat_dict_pushdown compress_unordered_sort compress_sort_transform \
       compression compression_sorted_merge transparent_decompression" \
  make installcheck-t
```

**Hinweis:** `installcheck-t` startet eine eigene temporäre PG-Instanz auf Port 55432. Falls du gegen die laufende lokale Instanz testen willst, nutze `installchecklocal-t` (braucht dann passwortlose `psql`-Verbindung als aktueller User).

## 8. Nach Code-Änderungen: Rebuild-Zyklus

```bash
cd build
make -j"$(nproc)"          # inkrementell kompilieren
sudo make install          # in PG installieren
sudo pg_ctlcluster 17 main restart   # Extension neu laden
```

Für reine Test-Änderungen (nur `.sql`/`.out`) reicht:
```bash
TESTS=compress_flat_dict_pushdown make installcheck-t
```

## Troubleshooting

| Problem | Lösung |
|---------|--------|
| `pg_config: not found` | `sudo apt install postgresql-server-dev-17` |
| `unicode/ucol.h: No such file` | `sudo apt install libicu-dev` |
| `initdb: not found` | `sudo apt install postgresql-17` |
| `TimeZone "US/Pacific" invalid` | `sudo apt install tzdata-legacy` |
| `shared_preload_libraries` Fehler | Pfad in `postgresql.conf` prüfen, dann `sudo pg_ctlcluster 17 main restart` |
| `-Werror` bei unbenutzten Funktionen | `pg_attribute_unused()` an die Funktion, oder entfernen |

---

## Alternative: Container (Podman/Docker)

Statt lokal zu installieren, kann alles in einem Container laufen. Das Repo
enthält ein Multi-Stage `Dockerfile` + `compose.yaml`.

### Starten

```bash
cd timescaledb
podman compose up -d
```

Beim ersten Mal wird das Image gebaut (kompiliert TimescaleDB im Container).
Danach startet es in Sekunden.

### Verbinden

```bash
psql -h localhost -p 5444 -U postgres -d tsdb
# Passwort: postgres
```

### Status / Logs

```bash
podman compose ps
podman compose logs -f timescaledb-dev
```

### Stoppen / Entfernen

```bash
# Stoppen (Daten bleiben im Volume):
podman compose down

# Stoppen + Volume löschen (alles weg):
podman compose down -v
```

### Neu bauen nach Code-Änderungen

```bash
podman compose build --no-cache
podman compose up -d
```

Oder in einem Schritt:
```bash
podman compose up -d --build
```

### Konfiguration (compose.yaml)

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `POSTGRES_USER` | `postgres` | Superuser-Name |
| `POSTGRES_PASSWORD` | `postgres` | Passwort |
| `POSTGRES_DB` | `tsdb` | Datenbank (wird beim ersten Start angelegt) |
| Port | `5444` | Host-Port (intern 5432) |

### Wie es funktioniert

1. **Builder-Stage**: Basiert auf `postgres:17-bookworm`, installiert Build-Tools,
   kompiliert TimescaleDB, legt Artefakte in `/install/` ab
2. **Runtime-Stage**: Frisches `postgres:17-bookworm`, kopiert nur die fertigen
   `.so` + `.sql` + `.control`-Dateien, konfiguriert `shared_preload_libraries`,
   erstellt die Extension automatisch beim ersten Start
