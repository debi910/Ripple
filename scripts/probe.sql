CREATE SCHEMA IF NOT EXISTS RIPPLE_PROBE;
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT RIPPLE_PROBE.PKGS() RETURNS VARCHAR(2000000) AS
import sys, importlib
def run(ctx):
    out = [sys.version.split()[0]]
    for m in ["numpy", "pandas", "scipy", "sklearn", "rapidfuzz", "jellyfish", "requests"]:
        try:
            mod = importlib.import_module(m); out.append(m + "=" + getattr(mod, "__version__", "?"))
        except Exception as e:
            out.append(m + "=missing")
    return ", ".join(out)
/
SELECT RIPPLE_PROBE.PKGS();
SELECT EDIT_DISTANCE('priya sharma','priya sharmaa') AS ED, SOUNDEX('Sharma') AS SX;
