"""Dev helper: run SQL from the command line or a file and print the result."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ripple.db import connect  # noqa: E402

sql = Path(sys.argv[1][1:]).read_text() if sys.argv[1].startswith("@") else sys.argv[1]
conn = connect()
for stmt in [s for s in sql.split(";\n") if s.strip()]:
    st = conn.execute(stmt)
    if st.result_type == "resultSet":
        import pandas as pd
        df = pd.DataFrame(st.fetchall())
        with pd.option_context("display.width", 250, "display.max_columns", 40, "display.max_colwidth", 120):
            print(df.to_string(index=False))
    else:
        print(f"ok ({st.rowcount()} rows)")
