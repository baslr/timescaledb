# Host-Session: flat_dictionary Per-Segment-Cache — Build & Test

Diese Datei ist die Arbeitsanleitung für die **Session auf dem Build-Host**
(Linux-Server mit PostgreSQL-Dev-Toolchain). Der Code wurde auf dem
Entwicklungsrechner geschrieben, aber dort fehlt `pg_config` — **Kompilieren,
Tests und das Generieren der erwarteten `.out`-Datei laufen hier auf dem Host.**

## Was umgesetzt wurde (Kurzfassung)

Per-Segment-Dictionary-Cache für die `flat_dictionary`-Kompression, damit der
Planner-Guard entfallen kann. Dadurch sind für flat_dict-Tabellen wieder
erlaubt: **Reverse-Scan, Batch-Sorted-Merge und Compressed-Sort-Pushdown**
(vorher: erzwungener separater `Sort` über einem Forward-ColumnarScan).

Kernidee: Statt eines überschriebenen Einzel-Slots eine **Map
`serialisierte segmentby-Werte → FlatDictionaryContext`** im Columnar-Scan.
Forward-Normalscan füllt sie beim Lesen der Dict-Row (`count==0`); die
reordernden Lesemodi (Reverse/BSM/Sort) lösen bei Cache-Miss einen **einmaligen
Prefetch** aus, der den komprimierten Chunk seq-scannt und alle Dict-Rows lädt.

Die Bulk-Pfade (`decompress_chunk`, Recompress, DML) bleiben **unverändert** —
reine Forward-Reads, bei denen die Dict-Row immer vor ihren Daten kommt.

## Geänderte / neue Dateien

Neu:
- `tsl/src/nodes/columnar_scan/flat_dict_cache.h`
- `tsl/src/nodes/columnar_scan/flat_dict_cache.c`
- `tsl/test/sql/compress_flat_dict_pushdown.sql`

Geändert:
- `tsl/src/nodes/columnar_scan/decompress_context.h`
  — Einzel-Slot `flat_dict_ctx` entfernt; `flat_dict_cache`, `chunk_relid`,
    `has_flat_dict_columns` hinzugefügt.
- `tsl/src/nodes/columnar_scan/compressed_batch.h`
  — `flat_dict_ctx` am `DecompressBatchState` (per-Batch statt scan-weit).
- `tsl/src/nodes/columnar_scan/compressed_batch.c`
  — Cache-Erzeugung, per-Batch-Auflösung, Reverse-Iterator, Prefetch-on-miss.
- `tsl/src/nodes/columnar_scan/columnar_scan.c`
  — Guard in `build_sortinfo` entfernt; segmentby-Spalten für flat_dict in den
    komprimierten Scan-Output gezwungen (`compressed_rel_setup_reltarget`).
- `tsl/src/nodes/columnar_scan/exec.c`
  — neue `dcontext`-Felder am Scan-Init gesetzt (inkl. settings-Lookup).
- `tsl/src/nodes/columnar_scan/CMakeLists.txt` — `flat_dict_cache.c` registriert.
- `tsl/test/sql/CMakeLists.txt` — Test registriert.

> **Nicht** geändert: `tsl/src/compression/compression.{c,h}` (Bulk-Pfade
> bewusst unangetastet). Falls ein Build-Fehler dort auftaucht, ist etwas
> schiefgelaufen — siehe Troubleshooting.

## 1. Build

Vom Repo-Root (`timescaledb-2.27.2/`). Debug-Build mit Assertions, damit die
`Assert(...)` im neuen Cache-Code wirklich greifen:

```bash
# Falls noch kein build/ existiert:
./bootstrap -DCMAKE_BUILD_TYPE=Debug -DASSERTIONS=ON

# Inkrementell bauen + installieren (lokale PG-Instanz):
cd build
make -j"$(nproc)"
sudo make install      # je nach Setup ohne sudo, wenn PG im $HOME liegt
```

Wenn `flat_dict_cache.c` neu hinzugekommen ist, muss CMake die Quellliste neu
einlesen. `make` triggert das normalerweise selbst; falls nicht:

```bash
cd build && cmake . && make -j"$(nproc)"
```

Erwartung: sauberer Compile. Der Code wurde ohne lokalen Compiler geschrieben,
daher bitte **besonders auf Warnungen achten** (Build läuft ggf. mit `-Werror`).
Wahrscheinlichste Stolpersteine sind Includes/Signaturen — siehe
Troubleshooting unten.

## 2. Test ausführen & erwartete Ausgabe generieren

Der neue Test ist `compress_flat_dict_pushdown` (reines `.sql`, kein Template).
Es gibt **noch keine** `tsl/test/expected/compress_flat_dict_pushdown.out` —
die muss hier erzeugt und auf Plausibilität geprüft werden.

### 2a. Test einmal laufen lassen (erzeugt results/, schlägt mangels .out fehl)

`TESTS` ist eine **Environment-Variable** (wird von `test/pg_regress.sh`
gelesen), kein make-Argument — daher dem Befehl voranstellen:

```bash
cd build
# Nur diesen einen Test gegen eine temporäre Instanz:
TESTS=compress_flat_dict_pushdown make -C tsl/test installcheck
# oder, je nach Setup, die lokale Variante (existierende PG-Instanz):
TESTS=compress_flat_dict_pushdown make -C tsl/test installchecklocal
```

`TESTS` unterstützt Wildcards (z. B. `TESTS="compression*"`).
Das tatsächliche Ergebnis landet unter
`build/tsl/test/results/compress_flat_dict_pushdown.out`.

### 2b. Ergebnis INHALTLICH prüfen (wichtig!)

Bevor das Ergebnis als „erwartet" eingefroren wird, manuell verifizieren:

1. **ORDER BY-Pushdown**: In den `EXPLAIN`-Ausgaben für die Single-Segment-
   Queries darf **kein separater `Sort`-Knoten** über dem `Custom Scan
   (ColumnarScan)` stehen (vorher war genau das der Fall). Bei der
   Multi-Segment-Query sollte `Batch Sorted Merge`/Pushdown erscheinen.
2. **Reverse korrekt**: `ORDER BY time DESC` liefert dieselben Tag-Werte wie
   `ASC`, nur umgekehrt — keine NULLs, keine vertauschten Segmente.
3. **Multi-Segment**: `d1` liefert nur `tag-a/b/c`, `d2` nur `tag-x/y/z`.
   Keine Vermischung (das wäre der Cross-Segment-Dictionary-Bug).

### 2c. Erwartete Ausgabe einfrieren

Wenn 2b passt:

```bash
cp build/tsl/test/results/compress_flat_dict_pushdown.out \
   tsl/test/expected/compress_flat_dict_pushdown.out
```

Danach erneut laufen lassen — jetzt muss der Test **grün** sein:

```bash
TESTS=compress_flat_dict_pushdown make -C tsl/test installcheck
```

## 3. Achtung: Determinismus der Test-Ausgabe

Der Test enthält Queries, deren Sortierung **nicht voll eindeutig** ist und auf
einem anderen Host/PG-Build instabil sein könnte:

- **`fd_metrics ... ORDER BY time` (Multi-Segment)**: Bei gleichem `time`
  existieren Zeilen aus `d1` **und** `d2` (beide haben `00:00–05:00`). Ohne
  zweiten Sortierschlüssel ist die Reihenfolge dieser Kollisionen
  implementierungsabhängig.
- **`fd_metrics ... ORDER BY time DESC`**: dasselbe.
- **`fd_many ... ORDER BY time ASC/DESC LIMIT 5`**: `time` ist hier eindeutig
  (Minuten-Schritte), also stabil — ok.

**Empfehlung vor dem Einfrieren der `.out`:** Falls die Kollisions-Queries
wackeln, in `tsl/test/sql/compress_flat_dict_pushdown.sql` einen Tiebreaker
ergänzen, z. B.:

```sql
-- statt:   ORDER BY time
SELECT time, device, tags FROM fd_metrics ORDER BY time, device;
-- statt:   ORDER BY time DESC
SELECT time, device, tags FROM fd_metrics ORDER BY time DESC, device;
```

Das ändert nichts an der getesteten Logik (die Dictionary-Auflösung wird trotzdem
über mehrere Segmente hinweg ausgeübt), macht die Ausgabe aber reproduzierbar.
Der `EXPLAIN` der Pushdown-Prüfung bleibt davon unberührt.

> Hinweis: Die explizite Tiebreaker-Variante wurde bewusst NICHT vorab
> eingebaut, damit am Host sichtbar bleibt, ob der Pushdown auch ohne
> zusätzlichen Sortierschlüssel greift. Nach der Verifikation gern anpassen.

## 4. Troubleshooting (Code wurde ohne lokalen Compiler geschrieben)

Wahrscheinlichste Fehlerquellen, nach Risiko sortiert:

### 4a. simplehash-Template (`flat_dict_cache.c`)
Der Cache nutzt `lib/simplehash.h` mit `SH_PREFIX flat_dict_ht`. Risiken:
- **Unbenutzte statische Funktionen** unter `-Werror`: `static inline` löst
  i. d. R. **kein** `-Wunused-function` aus. Falls doch eine generierte
  `flat_dict_ht_*`-Funktion moniert wird → entweder `(void)`-Referenz ergänzen
  oder Template-Scope prüfen (Vergleich: `tsl/src/compression/algorithms/dictionary_hash.h`).
- **`status`-Feld**: `FlatDictCacheItem.status` ist `uint16` (wie in
  `dictionary_hash.h`). Falls der Compiler ein anderes Statusfeld erwartet,
  an `dictionary_hash.h` angleichen.
- **`private_data`-Signatur**: `flat_dict_ht_create(mctx, 16, &cache->priv)` —
  dritter Parameter ist `void *private_data`. Falls die lokale PG-Version eine
  andere `_create`-Signatur generiert, an die PG-Version anpassen.

### 4b. Includes / Symbole
Falls „implicit declaration" o. Ä.:
- `flat_dict_cache.c`: `namestrcmp` ← `utils/builtins.h`; `hash_bytes` ←
  `common/hashfn.h`; `PG_DETOAST_DATUM` ← `access/detoast.h`;
  `table_open/table_beginscan` ← `access/table.h` / `access/tableam.h`;
  `GetActiveSnapshot` ← `utils/snapmgr.h`; `ts_chunk_get_by_*` ← `chunk.h`.
- `build_decompressor`, `row_decompressor_close`,
  `flat_dict_decompress_load_dictionary` sind in `compression/compression.h`
  als `extern` deklariert (geprüft).

### 4c. `datum_serialize`-Key-Alignment
`flat_dict_cache_build_key` baut den Schlüssel aus `datum_get_bytes_size` +
`datum_to_bytes_and_advance` relativ zum Offset `used`. Beide richten konsistent
am selben Offset aus (Buffer ist MAXALIGN'd). **Wenn** Lookups trotz gleicher
Segmentwerte nie treffen (Dauer-Prefetch, langsam), hier ansetzen: prüfen, ob
Prefetch (physische Heap-Attnos) und Executor (Scan-Output-Attnos) wirklich
byte-identische Keys erzeugen.

### 4d. segmentby nicht im Scan-Output
Symptom: `elog(ERROR, "... segmentby column \"X\" not found ...")` oder falsche
Dictionary-Treffer bei Queries, die **nur** die flat_dict-Spalte selektieren.
Ursache wäre, dass das segmentby-Forcing in `compressed_rel_setup_reltarget`
nicht greift. Gegencheck: `EXPLAIN (VERBOSE)` der betroffenen Query — die
segmentby-Spalte muss im Output des komprimierten Scans auftauchen.

## 5. Regressionscheck (nichts anderes kaputt?)

Da der Guard entfernt wurde und segmentby-Spalten erzwungen werden, können sich
Pläne **anderer** Kompressionstests ändern. Mindestens diese Suite mitlaufen
lassen und Diffs prüfen:

```bash
TESTS="compress_flat_dict_pushdown compress_unordered_sort compress_sort_transform \
       compression compression_sorted_merge transparent_decompression" \
  make -C tsl/test installcheck
```

- Plan-Diffs in **Nicht**-flat_dict-Tests sind ein Warnsignal: das
  segmentby-Forcing ist auf flat_dict-Tabellen beschränkt (Guard:
  `settings->fd.algorithm` gesetzt). Tritt dort ein Diff auf → prüfen, ob die
  Bedingung in `compressed_rel_setup_reltarget` zu weit gefasst ist.
- flat_dict gibt es erst seit Commit `98d8dbdba`; vorher existierende Tests
  nutzen es nicht, sollten also unverändert grün bleiben.

> `transparent_decompression` ist ein `.sql.in`-Template und wird pro
> PG-Version generiert (z. B. `transparent_decompression-17`). Falls
> `TESTS=transparent_decompression` nicht greift, den versionierten Namen
> verwenden oder einfach die volle Suite ohne `TESTS=` laufen lassen.

## 6. Commit

Wenn Build grün, der neue Test grün und die Regressionssuite ohne unerwartete
Diffs:

```bash
git add tsl/src/nodes/columnar_scan/flat_dict_cache.h \
        tsl/src/nodes/columnar_scan/flat_dict_cache.c \
        tsl/src/nodes/columnar_scan/decompress_context.h \
        tsl/src/nodes/columnar_scan/compressed_batch.h \
        tsl/src/nodes/columnar_scan/compressed_batch.c \
        tsl/src/nodes/columnar_scan/columnar_scan.c \
        tsl/src/nodes/columnar_scan/exec.c \
        tsl/src/nodes/columnar_scan/CMakeLists.txt \
        tsl/test/sql/compress_flat_dict_pushdown.sql \
        tsl/test/expected/compress_flat_dict_pushdown.out \
        tsl/test/sql/CMakeLists.txt \
        PLAN-flat-dictionary-per-segment-cache.md

git commit -m "Add per-segment flat_dictionary cache; enable sort pushdown"
```

> `HOST-SESSION-flat-dict-cache.md` (diese Datei) und ggf. die generierte
> `results/`-Ausgabe **nicht** mitcommitten.

## 7. Checkliste

- [ ] `make` ohne Fehler/Warnungen
- [ ] `make install`
- [ ] Test einmal gelaufen → `results/compress_flat_dict_pushdown.out` existiert
- [ ] Ausgabe inhaltlich geprüft (Pushdown ohne Sort / Reverse korrekt / keine
      Segment-Vermischung)
- [ ] ggf. Tiebreaker ergänzt (Abschnitt 3)
- [ ] `.out` nach `tsl/test/expected/` kopiert
- [ ] Test grün
- [ ] Regressionssuite ohne unerwartete Plan-Diffs
- [ ] committet






