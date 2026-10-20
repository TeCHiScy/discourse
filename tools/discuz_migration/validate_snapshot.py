#!/usr/bin/env python3
"""Compare row counts represented by an encrypted mysqldump with local MySQL."""

import os
import re
import subprocess
from collections import defaultdict

SNAPSHOT = "/Users/daren/discourse-lab/baseline/sinofsx-bbs-ucenter-20261009T215026+0800.sql.gz.gpg"
MYSQL = "/opt/homebrew/opt/mysql-client/bin/mysql"
DATABASES = {"bbs", "ucenter"}

USE_RE = re.compile(rb"^\s*USE\s+\x60([^\x60]+)\x60\s*;", re.I)
CREATE_RE = re.compile(
    rb"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:\x60([^\x60]+)\x60\s*\.\s*)?\x60([^\x60]+)\x60",
    re.I,
)
INSERT_RE = re.compile(
    rb"^\s*(?:INSERT|REPLACE)\s+INTO\s+(?:\x60([^\x60]+)\x60\s*\.\s*)?\x60([^\x60]+)\x60",
    re.I,
)
VALUES_RE = re.compile(rb"\bVALUES\b", re.I)
STRING_RE = re.compile(
    rb"'(?:\\.|''|[^'\\])*'|\"(?:\\.|\"\"|[^\"\\])*\"",
    re.S,
)


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def sql_ident(value):
    tick = chr(96)
    return tick + value.replace(tick, tick + tick) + tick


def mysql_base():
    return [
        MYSQL, "--protocol=tcp", "--host=127.0.0.1", "--port=13306",
        "--user=root", "--ssl-mode=DISABLED", "--batch", "--raw",
        "--skip-column-names", "--default-character-set=utf8mb4",
    ]


def count_dump_rows(passphrase):
    read_fd, write_fd = os.pipe()
    gpg = subprocess.Popen(
        [
            "gpg", "--batch", "--no-tty", "--pinentry-mode", "loopback",
            "--passphrase-fd", str(read_fd), "--decrypt", SNAPSHOT,
        ],
        stdout=subprocess.PIPE,
        pass_fds=(read_fd,),
    )
    os.close(read_fd)
    try:
        os.write(write_fd, (passphrase + "\n").encode())
    finally:
        os.close(write_fd)

    decompressor = subprocess.Popen(
        ["gzip", "-dc"], stdin=gpg.stdout, stdout=subprocess.PIPE
    )
    gpg.stdout.close()

    current_db = None
    tables = set()
    row_counts = defaultdict(int)
    statement = None
    statement_db = None

    for line in decompressor.stdout:
        if statement is None:
            use = USE_RE.match(line)
            if use:
                current_db = use.group(1).decode("utf-8")
            create = CREATE_RE.match(line)
            if create:
                schema = create.group(1).decode("utf-8") if create.group(1) else current_db
                table = create.group(2).decode("utf-8")
                if schema in DATABASES:
                    tables.add((schema, table))
            insert = INSERT_RE.match(line)
            if not insert:
                continue
            schema = insert.group(1).decode("utf-8") if insert.group(1) else current_db
            if schema not in DATABASES:
                continue
            statement = bytearray(line)
            statement_db = schema
            if not line.rstrip().endswith(b";"):
                continue
        else:
            statement.extend(line)
            if not line.rstrip().endswith(b";"):
                continue

        statement_bytes = bytes(statement)
        match = INSERT_RE.match(statement_bytes)
        values = VALUES_RE.search(statement_bytes, match.end() if match else 0)
        if not match or not values:
            raise RuntimeError("could not parse an INSERT statement from the snapshot")
        schema = match.group(1).decode("utf-8") if match.group(1) else statement_db
        table = match.group(2).decode("utf-8")
        if schema in DATABASES:
            payload = STRING_RE.sub(b"", statement_bytes[values.end():])
            depth = 0
            count = 0
            for char in payload:
                if char == 40:
                    if depth == 0:
                        count += 1
                    depth += 1
                elif char == 41:
                    depth -= 1
            if depth != 0:
                raise RuntimeError(f"unbalanced tuple delimiters in {schema}.{table}")
            row_counts[(schema, table)] += count
        statement = None
        statement_db = None

    if statement is not None:
        raise RuntimeError("snapshot ended inside an INSERT statement")
    decompressor.stdout.close()
    gzip_status = decompressor.wait()
    gpg_status = gpg.wait()
    if gpg_status or gzip_status:
        raise RuntimeError(f"snapshot stream check failed (gpg={gpg_status}, gzip={gzip_status})")
    return tables, dict(row_counts)


def local_table_names(mysql_env):
    query = (
        "SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA IN ('bbs','ucenter') AND TABLE_TYPE='BASE TABLE' "
        "ORDER BY TABLE_SCHEMA,TABLE_NAME"
    )
    result = subprocess.run(
        mysql_base() + ["--execute", query],
        env=mysql_env, text=True, capture_output=True, check=True,
    )
    return {
        tuple(line.split("\t", 1))
        for line in result.stdout.splitlines()
        if line.strip()
    }


def local_row_counts(mysql_env, tables):
    statements = []
    for schema, table in sorted(tables):
        statements.append(
            "SELECT "
            + sql_string(schema)
            + ","
            + sql_string(table)
            + ",COUNT(*) FROM "
            + sql_ident(schema)
            + "."
            + sql_ident(table)
        )
    result = subprocess.run(
        mysql_base(),
        input=";\n".join(statements) + ";\n",
        env=mysql_env, text=True, capture_output=True, check=True,
    )
    counts = {}
    for line in result.stdout.splitlines():
        schema, table, rows = line.split("\t")
        counts[(schema, table)] = int(rows)
    return counts


def main():
    passphrase = os.environ.pop("DUMP_KEY")
    mysql_password = os.environ.pop("MYSQL_PWD")
    mysql_env = os.environ.copy()
    mysql_env["MYSQL_PWD"] = mysql_password
    del mysql_password

    snapshot_tables, snapshot_counts = count_dump_rows(passphrase)
    del passphrase
    restored_tables = local_table_names(mysql_env)
    actual_counts = local_row_counts(mysql_env, restored_tables)

    missing = sorted(snapshot_tables - restored_tables)
    unexpected = sorted(restored_tables - snapshot_tables)
    mismatches = []
    for table in sorted(snapshot_tables | restored_tables):
        expected = snapshot_counts.get(table, 0)
        actual = actual_counts.get(table)
        if expected != actual:
            mismatches.append((table, expected, actual))

    print(f"snapshot_tables={len(snapshot_tables)}")
    print(f"restored_tables={len(restored_tables)}")
    print(f"snapshot_insert_rows={sum(snapshot_counts.values())}")
    print(f"restored_rows={sum(actual_counts.values())}")
    print(f"missing_tables={len(missing)}")
    print(f"unexpected_tables={len(unexpected)}")
    print(f"rowcount_mismatches={len(mismatches)}")
    for (schema, table), expected, actual in mismatches[:50]:
        print(f"mismatch={schema}.{table} snapshot={expected} restored={actual}")
    if missing or unexpected or mismatches:
        raise SystemExit(1)
    print("baseline_validation=passed")


if __name__ == "__main__":
    main()
