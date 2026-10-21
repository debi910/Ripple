# Run guide

From a clean machine to the Ripple app in four steps. Building the demo world
takes about two minutes once Exasol is running.

## 1. Install and start Exasol Personal

Ripple uses [Exasol Personal](https://github.com/exasol/exasol-personal) as its
only data platform. Install the launcher and start a local database. Starting
it means you accept Exasol's Personal EULA.

**Linux, or macOS on Apple silicon**

```bash
curl https://downloads.exasol.com/exasol-personal/installer.sh | sh
exasol install local
exasol slc install PYTHON3      # Python runtime for UDFs; restarts the database
```

On Linux the database runs in Podman, so install Podman first
(`sudo apt install podman` on Ubuntu).

**Windows 10/11 (tested setup)**

We ran Ripple on Windows 11 with Exasol inside WSL 2 (Ubuntu 24.04):

```bash
wsl --install -d Ubuntu          # in PowerShell, if WSL is not set up yet
```

Then inside the Ubuntu shell:

```bash
sudo apt update && sudo apt install -y podman
curl https://downloads.exasol.com/exasol-personal/installer.sh | sh
~/.local/bin/exasol install local
~/.local/bin/exasol slc install PYTHON3
```

WSL forwards `localhost:8563` to Windows, so the Python steps below run in a
normal Windows terminal. The launcher can also prepare a Podman machine
natively on Windows (it needs `winget`); see the Exasol Personal docs.

**Check it works**

```bash
exasol info        # connection details
exasol connect     # SQL shell; try SELECT 1;
```

Exasol's memory needs are modest: on an 8 GB laptop WSL gets about 4 GB, which
holds the demo world comfortably and the large world too.

## 2. Install the Python side

Python 3.11 or newer.

```bash
git clone https://github.com/debi910/Ripple.git
cd Ripple
python -m pip install -r requirements.txt
```

### Connection settings

| Variable | Default |
|---|---|
| `RIPPLE_DSN` | `localhost:8563` |
| `RIPPLE_USER` | `sys` |
| `RIPPLE_PASSWORD` | read from the launcher's `secrets.json` (`~/.exasol/personal/deployments/default/`, also found through `\\wsl.localhost` on Windows) |
| `RIPPLE_PORT` | `8765`, the web app's port |

TLS is on. Certificate checks are off because Exasol Personal ships a
self-signed certificate.

## 3. Build the world and run the engines

```bash
python -m ripple.build                 # demo: 12 stores, 40k shoppers, 120 days, seed 42
python -m ripple.build --scale large   # 30 stores, 200k shoppers, 180 days
python -m ripple.build --scale tiny    # a quick smoke test
python -m ripple.build --seed 7        # a different world, same method
```

This generates CSVs into `data/<scale>/`, bulk-loads them with Exasol `IMPORT`
over pyexasol's HTTP transport, and runs every stage in `sql/` in order. Each
step's duration goes into `RIPPLE.RUN_TIMINGS`.

Stages can also be run on their own:

```bash
python -m ripple.load data/demo        # schema + load only
python -m ripple.pipeline              # all engines
python -m ripple.pipeline 40 60        # just the detector and the ledger
```

## 4. Open the app

```bash
python -m ripple.app                   # http://localhost:8765
```

| Tab | What it shows |
|---|---|
| **The bill** | Total cost of all phantom stock-outs against the lost-sale view, the five-system chain, cost by category, the most expensive episodes |
| **Recount list** | The morning list per store, ranked by expected saving, with the evidence behind each alert. Drag the date to replay any morning |
| **Stock-out ripple** | One episode: its timeline, every shopper it touched (merged across accounts), and each shopper's receipts |
| **Proof** | Every engine scored against the simulator's answer key, the ablation, the causal check, the calibration and the stage timings |

The number at the top right is how long Exasol took to answer the current view.

## Reproducibility

The same seed gives the same world and the same numbers. Results for seed 42
are in the README. `RIPPLE.EVAL_METRICS` holds every metric the app shows.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `schema None not found` or auth errors | Set `RIPPLE_PASSWORD` to the `dbPassword` in the launcher's `secrets.json` |
| `script language PYTHON3 not found` | `exasol slc install PYTHON3` |
| `[WinError 10013]` when starting the app | Port reserved by Windows; set `RIPPLE_PORT` to another port |
| Connection refused on 8563 | `exasol start`; on Windows make sure the WSL distro is running |
| Shell scripts fail in WSL with `\r` errors | The repo forces LF for `*.sh` via `.gitattributes`; re-checkout if you copied files by hand |
