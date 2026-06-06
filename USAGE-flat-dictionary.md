# flat_dictionary Nutzung — Tabelle erstellen

## Voraussetzung

- TimescaleDB Extension ist geladen (`shared_preload_libraries = 'timescaledb'`)
- Extension in der Datenbank aktiv (`CREATE EXTENSION IF NOT EXISTS timescaledb;`)

## CREATE TABLE mit flat_dictionary

```sql
CREATE TABLE server_metrics_v2 (
    timestamp   TIMESTAMPTZ NOT NULL,
    host        UUID NOT NULL,
    metric      metric_name NOT NULL,
    value       DOUBLE PRECISION,
    tags        TEXT
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'timestamp',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'host, metric',
    tsdb.orderby = 'timestamp DESC',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
```

## Gültige `tsdb.*` Parameter

| Parameter | Beschreibung | Beispiel |
|-----------|-------------|----------|
| `tsdb.hypertable` | Macht die Tabelle zur Hypertable | (kein Wert, nur Flag) |
| `tsdb.partition_column` | Zeitspalte für Partitionierung | `'timestamp'` |
| `tsdb.chunk_interval` | Größe eines Chunks | `'1 hour'`, `'1 day'` |
| `tsdb.segmentby` | Kompression: Gruppierung | `'host, metric'` |
| `tsdb.orderby` | Kompression: Sortierung innerhalb eines Segments | `'timestamp DESC'` |
| `tsdb.compress_algorithm` | Kompressionsalgorithmus pro Spalte | `'tags flat_dictionary'` |

## Prüfen, dass flat_dictionary aktiv ist

```sql
SELECT relid::regclass, segmentby, orderby, algorithm
FROM _timescaledb_catalog.compression_settings
WHERE relid = 'server_metrics_v2'::regclass;
```

Erwartete Ausgabe:

```
      relid       |  segmentby   |   orderby   | algorithm
------------------+--------------+-------------+-----------
 server_metrics_v2 | {host,metric} | {timestamp} | {tags=8}
```

`{tags=8}` = flat_dictionary ist aktiv für die `tags`-Spalte.

## Compression Policy einrichten

```sql
SELECT add_compression_policy('server_metrics_v2', INTERVAL '1 hour');
```

Optional: Job-Intervall anpassen (Default 12h → z.B. 30min):

```sql
SELECT alter_job(job_id, schedule_interval => INTERVAL '30 minutes')
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_compression'
  AND hypertable_name = 'server_metrics_v2';
```

## Retention Policy (optional)

```sql
SELECT add_retention_policy('server_metrics_v2', INTERVAL '30 days');
```

## Mehrere Spalten mit flat_dictionary

```sql
tsdb.compress_algorithm = 'tags flat_dictionary, category flat_dictionary'
```

## Alternativer Weg (bestehende Tabelle nachträglich)

Falls die Tabelle schon existiert und bereits eine Hypertable ist:

```sql
ALTER TABLE server_metrics_v2 SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'host, metric',
    timescaledb.compress_orderby = 'timestamp DESC',
    timescaledb.compress_algorithm = 'tags flat_dictionary'
);
```

**Hinweis:** Der `ALTER TABLE`-Weg nutzt den `timescaledb.*`-Namespace (nicht `tsdb.*`).

## Daten von einer bestehenden Instanz streamen

Direkt pipen zwischen zwei PostgreSQL-Instanzen — kein Zwischenfile nötig:

```bash
psql -h localhost -p 5432 -U postgres -d tsdb \
  -c "COPY (SELECT * FROM server_metrics_v2 WHERE timestamp > now() - INTERVAL '24 hours') TO STDOUT WITH (FORMAT binary)" \
| psql -h localhost -p 5444 -U postgres -d tsdb \
  -c "COPY server_metrics_v2 FROM STDIN WITH (FORMAT binary)"
```

Intervall anpassen je nach Bedarf:

| Ausschnitt | WHERE-Klausel |
|-----------|---------------|
| Letzte Stunde | `timestamp > now() - INTERVAL '1 hour'` |
| Letzte 24h | `timestamp > now() - INTERVAL '24 hours'` |
| Letzte Woche | `timestamp > now() - INTERVAL '7 days'` |
| Alles | WHERE weglassen (`COPY server_metrics_v2 TO STDOUT ...`) |

Fortschritt prüfen (in einem zweiten Terminal):

```bash
psql -h localhost -p 5444 -U postgres -d tsdb \
  -c "SELECT count(*) FROM server_metrics_v2;"
```
