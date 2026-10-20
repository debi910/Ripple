"""Connection to Exasol Personal.

Defaults match a fresh `exasol install local`: user sys on localhost:8563, with
the password read from the launcher's secrets.json (also found through
\\wsl.localhost on Windows). Override with RIPPLE_DSN, RIPPLE_USER, RIPPLE_PASSWORD.
"""

import os
import re
import ssl
from pathlib import Path

import pyexasol

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"


def _launcher_password() -> str | None:
    """Read the password the Exasol launcher generated for the default local deployment."""
    import glob
    import json
    rel = ".exasol/personal/deployments/default/secrets.json"
    candidates = [Path.home() / rel] + [Path(p) for p in glob.glob(rf"\\wsl.localhost\*\home\*\{rel}")]
    for path in candidates:
        try:
            return json.loads(path.read_text())["dbPassword"]
        except (OSError, KeyError, ValueError):
            continue
    return None


def connect(schema: str | None = None, **kw) -> pyexasol.ExaConnection:
    return pyexasol.connect(
        dsn=os.environ.get("RIPPLE_DSN", "localhost:8563"),
        user=os.environ.get("RIPPLE_USER", "sys"),
        password=os.environ.get("RIPPLE_PASSWORD") or _launcher_password() or "exasol",
        schema=schema or "",
        encryption=True,
        # Exasol Personal ships a self-signed certificate.
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
        compression=True,
        fetch_dict=True,
        **kw,
    )


def split_statements(sql: str) -> list[str]:
    """Split a .sql file on ';' at line ends, keeping UDF bodies (which end with '/') whole."""
    statements, buf, in_script = [], [], False
    for line in sql.splitlines():
        stripped = line.strip()
        if not in_script and re.match(r"(?i)CREATE\s+(OR\s+REPLACE\s+)?(PYTHON3|LUA|JAVA|R)?\s*\w*\s*SCRIPT", stripped):
            in_script = True
        if in_script:
            if stripped == "/":
                statements.append("\n".join(buf))
                buf, in_script = [], False
            else:
                buf.append(line)
            continue
        if stripped.startswith("--") and not buf:
            continue
        buf.append(line)
        if stripped.endswith(";"):
            stmt = "\n".join(buf).strip().rstrip(";")
            if stmt and not all(l.strip().startswith("--") or not l.strip() for l in stmt.splitlines()):
                statements.append(stmt)
            buf = []
    tail = "\n".join(buf).strip().rstrip(";")
    if tail:
        statements.append(tail)
    return statements


def run_file(conn, name: str, verbose: bool = True):
    import time
    for stmt in split_statements((SQL_DIR / name).read_text(encoding="utf-8")):
        t = time.time()
        conn.execute(stmt)
        if verbose:
            head = " ".join(stmt.split())[:90]
            print(f"  {time.time() - t:6.2f}s  {head}")
