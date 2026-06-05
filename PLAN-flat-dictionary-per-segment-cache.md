# Plan: Echter Per-Segment-Dictionary-Cache für flat_dictionary

## Status quo

`flat_dictionary` funktioniert **funktional korrekt**, aber mit einer
Performance-Einschränkung. Dieser Plan dokumentiert den offenen Ausbauschritt:
den Wechsel von einem überschriebenen Einzel-Slot zu einem echten
Per-Segment-Cache, damit der Planner-Guard entfallen kann.

## Was der Cache aktuell ist

`dcontext->flat_dict_ctx` ist **ein einzelner Slot pro Scan-Node**, der pro
Segment überschrieben wird. Ablauf beim Vorwärts-Scan:

```
Dict-Row Segment A (count=0)  → flat_dict_ctx = DictionaryA   (überschreibt)
  Daten-Batch A1              → liest flat_dict_ctx = A  ✓
  Daten-Batch A2              → liest flat_dict_ctx = A  ✓
Dict-Row Segment B (count=0)  → flat_dict_ctx = DictionaryB   (überschreibt A)
  Daten-Batch B1              → liest flat_dict_ctx = B  ✓
  Daten-Batch B2              → liest flat_dict_ctx = B  ✓
```

Es ist „per Segment" in dem Sinne, dass der Slot zu jedem Zeitpunkt genau das
Dictionary des Segments enthält, dessen Daten-Batches gerade dekomprimiert
werden. Korrekt — **solange immer nur ein Segment gleichzeitig aktiv ist**.

Was es **nicht** ist: eine Map `segment → dictionary`, die mehrere Dictionaries
gleichzeitig vorhält. Sobald die Dict-Row von Segment B gelesen wird, ist
Dictionary A weg (überschrieben).

## Warum es trotzdem korrekt ist (zwei Bedingungen)

1. **Forward-Scan**: Die Dict-Row kommt physisch **vor** ihren Daten-Batches
   (der Compressor schreibt sie via `heap_insert` zuerst). Beim Lesen von A1/A2
   ist garantiert Dictionary A im Slot.
2. **Ein Segment zur Zeit**: Es werden nie Batches aus A und B verschränkt
   gelesen.

## Wo es bricht — und warum der Planner-Guard nötig ist

Zwei Lese-Modi würden Bedingung 1 oder 2 verletzen:

| Modus | Problem |
|-------|---------|
| **Reverse-Scan** | Daten-Batches kämen vor der Dict-Row → beim Lesen von A2/A1 ist der Slot noch leer (NULL) oder enthält das falsche Dictionary → `elog(ERROR)` oder falsche Werte |
| **Batch-Sorted-Merge** | Mischt Batches aus mehreren Segmenten gleichzeitig (A1, B1, A2, …) → der eine Slot kann nicht gleichzeitig A und B halten → falsches Dictionary |

Deshalb der Planner-Guard in `build_sortinfo` (`columnar_scan.c`): Für
flat_dict-Tabellen werden Reverse-Pushdown und Sorted-Merge abgeschaltet, sodass
der Planner stattdessen einen normalen Forward-Scan + ein explizites `Sort`
darüber baut. Damit halten Bedingung 1+2 immer.

**Kosten**: Sortierungen, die TimescaleDB sonst in den Scan pushen könnte,
landen als separater Sort-Schritt oben drauf → langsamer bei `ORDER BY`-Queries.

## Ziel: Echter Per-Segment-Cache

Statt eines überschriebenen Einzel-Slots eine **Map**
`segment-key → FlatDictionaryContext`, die mehrere Dictionaries gleichzeitig
vorhält. Dann können verschränkte Batches (Sorted-Merge) und Reverse-Scans
jeweils ihr eigenes Dictionary nachschlagen → der Guard wird überflüssig.

- **Schlüssel**: identifiziert das Segment eindeutig. Kandidaten: die
  segmentby-Spaltenwerte des Batches, oder ein leichteres Surrogat (z. B. die
  TID/Position der Dict-Row). Muss aus einem Daten-Batch ableitbar sein, ohne
  die Dict-Row erneut zu lesen.
- **Lebensdauer**: Scan-lifetime-Context (Parent von `per_batch_context`),
  wie schon heute beim Einzel-Slot — übersteht die Per-Batch-Resets.
- **Eviction**: optional. Für Korrektheit nicht nötig; bei sehr vielen Segmenten
  pro Scan ggf. LRU, um Speicher zu begrenzen.

## Implementierungsschritte

1. **Datenstruktur**: `dcontext->flat_dict_ctx` (Einzel-Pointer) ersetzen durch
   eine Hash-Map `flat_dict_cache` in `DecompressContext`
   (`decompress_context.h`). Analog `RowDecompressor.flat_dict_ctx` in
   `compression.h` für die Bulk-Pfade.
2. **Befüllen**: In `compressed_batch_load_flat_dict` (columnar scan) und
   `flat_dict_decompress_load_dictionary` (bulk) den fertigen Context unter dem
   Segment-Key in die Map legen statt den Slot zu überschreiben.
3. **Nachschlagen**: In `decompress_column` / `init_iterator` /
   `decompress_single_column` den Context per Segment-Key des aktuellen Batches
   aus der Map holen statt `dcontext->flat_dict_ctx` direkt zu lesen.
4. **Segment-Key aus Batch**: Mechanismus, um aus einem Daten-Batch seinen
   Segment-Key zu bestimmen (segmentby-Werte aus dem komprimierten Tuple lesen).
5. **Guard entfernen**: Den Early-Return in `build_sortinfo`
   (`columnar_scan.c`) löschen, damit Reverse-Pushdown und Sorted-Merge wieder
   für flat_dict-Tabellen erlaubt sind.
6. **Reverse-Scan-Pfad**: Sicherstellen, dass bei Reverse die Dict-Row, die
   physisch nach den Daten-Batches kommt, vor dem Nachschlagen geladen ist —
   oder die Map vor dem eigentlichen Scan in einem Vorlauf füllen.

## Tests

- `test_flat_dict_order_by_pushdown` — `ORDER BY` ohne separaten Sort-Schritt
  (EXPLAIN zeigt Pushdown statt Sort-Node).
- `test_flat_dict_reverse_scan` — Reverse-Scan liefert korrekte Werte.
- `test_flat_dict_sorted_merge_multi_segment` — verschränkte Batches aus
  mehreren Segmenten lösen das jeweils richtige Dictionary auf.
- `test_flat_dict_cache_many_segments` — Speicher bleibt beschränkt (falls
  Eviction implementiert wird).

## Einordnung

- **Aufwand**: mittel.
- **Funktional**: aktueller Stand ist korrekt (dank Guard); dies ist reine
  Performance-/Feature-Lockerung, kein Bugfix.
- **Nutzen**: macht flat_dict bei `ORDER BY`-Queries schneller und erlaubt
  Reverse-Scans.

## Betroffene Dateien

- `tsl/src/nodes/columnar_scan/decompress_context.h`
- `tsl/src/nodes/columnar_scan/compressed_batch.c`
- `tsl/src/nodes/columnar_scan/columnar_scan.c` (Guard entfernen)
- `tsl/src/compression/compression.h`
- `tsl/src/compression/compression.c`
