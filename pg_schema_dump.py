#!/usr/bin/env python3
"""Dump claude-ui's OWN database objects into claude-ui/sql/schema, one file per object.

Self-contained on purpose: the host project's dumper calls this (and `--list` to learn which files
are ours so it can drop them from its own tree) and knows nothing else. Ownership is by name: every
object claude-ui creates is named claude_* (tables, sequences, indexes, views, RPCs) -- see
sql/schema/order.txt for the current set. Same file-naming convention as the host's dumper so the
trees are interchangeable; the split/validate logic is duplicated here rather than imported, because
this directory is its own repository.

Config: DBURI (env, or the host's ../.env when vendored). CLAUDE_UI_SCHEMAS = schemas that may hold
our objects (default "<CLAUDE_UI_SCHEMA or public>,api").
Usage: python3 pg_schema_dump.py [--list]
"""
import os
import re
import subprocess
import sys
from pathlib import Path

DIR = Path(__file__).parent.absolute()
SCHEMA_DIR = DIR / "sql" / "schema"
OWNED = re.compile(r"claude_(msg|ctl|status|send|img)")


def load_env():
    env = dict(os.environ)
    for envf in (DIR / ".env", DIR.parent / ".env"):
        if envf.exists():
            for line in envf.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env.setdefault(k, v.strip().strip('"\''))
    return env


def generate_filename(content):
    m = re.search(r"Name: ([^;]+); Type: ([^;]+)", content)
    if not m:
        return None
    name, type_ = m.groups()
    sch = re.search(r"; Schema: ([^;]+)", content)
    schema = sch.group(1).strip() if sch and sch.group(1).strip() != "-" else ""
    fn = f"{schema}.{name}.{type_}" if schema else f"{name}.{type_}"
    fn = re.sub(r"(Name: |Type: |; |\(|\)| )", ".", fn)
    fn = re.sub(r"\.+", ".", fn)
    fn = re.sub(r"^\.", "", fn)
    fn = re.sub(r'"', "", fn)
    fn = fn.replace("/", "_slash_").replace("*", "_star_") + ".sql"
    return fn


def owned(chunk):
    m = re.search(r"^-- Name: ([^\n]*)", chunk, flags=re.MULTILINE)
    return bool(m and OWNED.search(m.group(1)))


def main():
    env = load_env()
    dburi = env.get("DBURI")
    if not dburi:
        print("DBURI not set", file=sys.stderr); sys.exit(1)
    data_schema = env.get("CLAUDE_UI_SCHEMA") or "public"
    schemas = [s.strip() for s in env.get("CLAUDE_UI_SCHEMAS", f"{data_schema},api").split(",") if s.strip()]
    args = []
    for s in schemas:
        args += ["--schema", s]
    res = subprocess.run(["pg_dump", "--schema-only", "--no-owner", *args, dburi],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f"pg_dump failed: {res.stderr}", file=sys.stderr); sys.exit(1)
    dump = "".join(l for l in res.stdout.splitlines(keepends=True)
                   if not l.startswith(("\\connect", "\\restrict", "\\unrestrict")))
    chunks = [c for c in re.split(r"(?=^-- Name: )", dump, flags=re.MULTILINE) if c.strip() and "-- Name:" in c]
    mine = [(generate_filename(c), c) for c in chunks if owned(c)]
    order = [fn for fn, _ in mine]
    if len(order) != len(set(order)):
        print("FILENAMES NOT UNIQUE!", file=sys.stderr); sys.exit(1)
    if "--list" in sys.argv:
        # the HOST-side filenames (what the host's dumper produced), so it can drop them from its tree
        print("\n".join(order)); return 0
    # HOST-NEUTRAL FILES. The live DB holds our objects in the host's data schema, gated by the host's
    # admin predicate and granted to the host's PostgREST roles. The committed files carry placeholders
    # instead, so the same tree installs into any project: sql/apply.sh renders them back.
    admin_fn = env.get("CLAUDE_UI_ADMIN_FN", f"{data_schema}.is_admin()")
    anon, auth = env.get("CLAUDE_UI_ANON_ROLE", "web_anon"), env.get("CLAUDE_UI_AUTH_ROLE", "authenticated")
    def neutral(text):
        text = text.replace(admin_fn, "@ADMIN@")
        text = re.sub(rf"\b{re.escape(data_schema)}\.", "@SCHEMA@.", text)
        text = text.replace(f"Schema: {data_schema};", "Schema: @SCHEMA@;")
        text = re.sub(rf"\bTO {anon}\b", "TO @ANON_ROLE@", text)
        text = re.sub(rf"\bTO {auth}\b", "TO @AUTH_ROLE@", text)
        return text
    SCHEMA_DIR.mkdir(parents=True, exist_ok=True)
    for f in SCHEMA_DIR.glob("*.sql"):
        f.unlink()
    out = []
    for fn, c in mine:
        c = re.sub(r"^CREATE (VIEW|FUNCTION)", r"CREATE OR REPLACE \1", c, flags=re.MULTILINE)
        nfn = re.sub(rf"^{re.escape(data_schema)}\.", "SCHEMA.", fn)
        (SCHEMA_DIR / nfn).write_text(neutral(c)); out.append(nfn)
    (SCHEMA_DIR / "order.txt").write_text("\n".join(out) + "\n")
    print(f"claude-ui: wrote {len(out)} host-neutral objects to {SCHEMA_DIR} "
          f"(schema {data_schema} -> @SCHEMA@, {admin_fn} -> @ADMIN@)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
