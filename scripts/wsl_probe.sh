#!/bin/bash
python3 -c 'import json;d=json.load(open("/home/debi91/.exasol/personal/deployments/default/secrets.json"));print({k:(type(v).__name__) for k,v in d.items()})'
echo "SELECT PARAM_VALUE FROM EXA_METADATA WHERE PARAM_NAME='databaseProductVersion';" | ~/.local/bin/exasol connect 2>&1 | tail -5
free -m | head -2
~/.local/bin/exasol slc --help 2>&1 | head -20
