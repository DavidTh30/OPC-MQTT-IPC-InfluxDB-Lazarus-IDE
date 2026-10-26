# InfluxDB Server (Lazarus)

A time-series database server that speaks the **InfluxDB 1.x HTTP API**, written in Free Pascal / Lazarus with normal forms. No DLL, no library. Tools made for InfluxDB work with it unchanged:
- **Grafana** (InfluxDB data source, query language InfluxQL)
- **Telegraf** (`outputs.influxdb`, also gzip)
- the `influx` CLI, `curl`
- the InfluxDB client libraries for 1.x, and the v2 libraries for writing

## Build and run

```bash
C:\lazarus\lazbuild.exe InfluxServer\InfluxServer.lpi
```

Press **Start** (`F5`). The defaults:
- **port 8086**, the InfluxDB port;
- data folder `data` next to the exe;
- databases are created on the first write.

The settings are saved in `InfluxServer.ini`.

| Window part | |
|---|---|
| Status line | writes / s, points / s, queries / s, totals, errors, bytes received |
| **Databases** tab | measurements, series, points, WAL size, retention per database; *Compact now* |
| **Query** tab | run InfluxQL inside the program (`F9` / `Ctrl+Enter`); the result is shown as a table and as the JSON the HTTP API returns |
| Log | start, loading, errors (every 4xx / 5xx request), retention; *Log every request* shows all of them |
| Retention days | 0 = keep everything; otherwise older points are removed once per minute |

## HTTP API

| Endpoint | |
|---|---|
| `GET /ping` | `204`, header `X-Influxdb-Version: 1.8.10-lazarus` (`?verbose=true` → `200` JSON) |
| `GET /health` | `200 {"status":"pass",...}` |
| `POST /write?db=..&precision=ns\|u\|ms\|s\|m\|h` | line protocol, also `Content-Encoding: gzip` |
| `POST /api/v2/write?bucket=db[/rp]&precision=..` | the same for InfluxDB 2.x clients (org and token are ignored) |
| `GET` / `POST /query?q=..&db=..&epoch=ms` | InfluxQL. With POST, `q` can also be a form field. Several statements are separated by `;`. Without `epoch`, times are RFC3339 |
| `POST /api/v2/query` | `501`: Flux is not supported, use InfluxQL on `/query` |

**Answers follow InfluxDB.** For example:
- a write with errors returns `400 partial write: unable to parse '...': ... dropped=1`, and the valid lines are still stored;
- a field written with another type than before returns `field type conflict`;
- an unknown database on a write returns `404 database not found` (with auto-create off).

**Access:** there is no login (anonymous); `u` / `p` and tokens are ignored. Responses carry CORS headers.

```bash
curl -i -XPOST "http://localhost:8086/write?db=plant&precision=s" --data-binary "hv,unit=1 kv=7.5,ma=6.9 1761465600"
curl -G "http://localhost:8086/query?db=plant" --data-urlencode "q=SELECT mean(kv) FROM hv WHERE time > now() - 1h GROUP BY time(1m)"
```

## InfluxQL

```
SELECT <expr> [AS name], ... FROM m | "db"."rp"."m" | /regex/
  [WHERE ...] [GROUP BY time(10s[, offset]), tag, ... | *] [fill(null|none|previous|linear|0)]
  [ORDER BY time DESC] [LIMIT n] [OFFSET n] [SLIMIT n] [SOFFSET n] [tz('...')]
```

- **Values:** fields, tags, `*` (all fields and tags), arithmetic `+ - * / %`, `"name"::field` / `::tag`.
- **Aggregates:** `count sum mean median min max first last spread stddev mode percentile(x, N)`. They can also be written as `mean(*)` and used in arithmetic (`mean(a) * 2`).
  - `first` / `last` / `min` / `max` alone keep the time of their point.
- **Transforms** of a raw field or of an aggregate: `derivative(x[, 1s])`, `non_negative_derivative`, `difference`, `non_negative_difference`, `cumulative_sum`, `moving_average(x, N)`, `elapsed(x[, unit])`.
- **WHERE:**
  - time: `time > now() - 1h`, `time >= '2026-10-26T08:00:00Z'`, `time <= 1761465600000ms` (Grafana's `$timeFilter`);
  - tags and fields: `= != <> < <= > >=` and `=~ !~ /regex/`;
  - combined with `AND`, `OR`, `( )`.
- **GROUP BY time** without an upper time bound ends at `now()`, and buckets are aligned to the epoch (plus the offset), as in InfluxDB.
- **Other statements:**
  - `SHOW DATABASES | MEASUREMENTS [WITH MEASUREMENT =~ /re/] | TAG KEYS | TAG VALUES WITH KEY = "k" | IN (..) | =~ /re/ | FIELD KEYS | SERIES | RETENTION POLICIES | USERS`, with `ON db`, `FROM`, `WHERE` and `LIMIT`;
  - `CREATE DATABASE`, `DROP DATABASE`, `DROP MEASUREMENT`, `DROP SERIES [FROM m] WHERE tag = ..`, `DELETE [FROM m] [WHERE time / tags]`;
  - retention policy, user and grant statements are accepted and do nothing. There is one policy, `autogen`.

**Not supported:**
- Flux;
- subqueries, `SELECT INTO`, more than one measurement after `FROM` (use a regex);
- continuous queries, `GROUP BY` with a regex of tag names (it is treated as `*`);
- chunked responses (the whole answer comes at once);
- authentication, TLS.

## Grafana

*Connections → Data sources → InfluxDB*:
- **Query language** InfluxQL;
- **URL** `http://localhost:8086`;
- **Database** the name of your database;
- *Save & test* shows success.

The query editor lists the measurements, fields and tag values; `$timeFilter`, `$__interval` and `fill()` work.

## Client and test data

- [InfluxClient](../InfluxClient/README.md): browse the databases, run InfluxQL, and show the results as a table or a chart.
- [InfluxSignalGen](../InfluxSignalGen/README.md): fills a database with test signals, live or as history.
- [InfluxMachine](../InfluxMachine/README.md): a machine and its BGRABitmap HMI that talk only through this server (data, events and commands).

## PLC Data Logger

The [DataLogger](../DataLogger/README.md) has an InfluxDB output (*Network Config → InfluxDB Output...*). Every logged row becomes one point with the tags as fields, so PLC values can go to this server and on to Grafana.

## Telegraf

```toml
[[outputs.influxdb]]
  urls = ["http://127.0.0.1:8086"]
  database = "telegraf"
  content_encoding = "gzip"
```

## Storage

- **Memory:** everything is held in memory: database → measurement → series (one per tag set) → one column per field, sorted by time. A value at the same series, field and time replaces the old one.
- **Disk:** each database is a folder `data\<db>\`:
  - `wal.lp`: every accepted write in line protocol with ns times. It is appended once per request, so a crash or kill loses nothing that was answered with 204.
  - `snapshot.lp`: the whole database, written at *Stop*, by *Compact now*, after a DELETE / DROP, by retention, and when the WAL passes 64 MB. Then the WAL starts again empty.
  - **Loading** = snapshot + WAL. Both are plain text, so they can be read or edited, and any tool can import them through `/write`.
- **Locking:** one reader / writer lock: queries run at the same time, a write waits for them.

**Measured on this PC** (Python client, batches of 5000 lines):

| | |
|---|---|
| writes | about 55,000 points / s |
| `GROUP BY time(1m), host` with 3 aggregates over 200,000 points | about 0.45 s |
| `count()` over 200,000 points | about 80 ms |
| `SELECT * ... WHERE host = 'h3' LIMIT 5` | 2 ms |
| memory with 200,000 points | about 24 MB |
| snapshot of 200,000 points | 11.9 MB |

## Files

```
InfluxServer.lpi / .lpr   project
uinfluxmain.pas / .lfm    main window (designer form)
uinfluxhttp.pas           HTTP API (fphttpserver in its own thread), gzip, endpoints
uqueryexec.pas            InfluxQL execution, aggregates, fill, transforms, JSON
uinfluxql.pas             InfluxQL lexer and parser
utsdb.pas                 store: databases, series, columns, WAL, snapshot, retention
ulineproto.pas            line protocol parser / writer
```
