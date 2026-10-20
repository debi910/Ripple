#!/bin/bash
# Run a SQL file through the Exasol launcher's SQL shell (dev helper).
~/.local/bin/exasol connect < "$1" 2>&1 | grep -v "Using default deployment"
