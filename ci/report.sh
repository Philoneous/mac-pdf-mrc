#!/usr/bin/env bash
# CI: Befehl ausführen; schlägt er fehl, die letzten Ausgabezeilen als Fehler-Annotation melden
# (Annotationen sind über die Checks-API lesbar, auch ohne Zugriff auf Logs und Artefakte).
#   bash ci/report.sh <Titel> <Befehl …>
set -uo pipefail
title="$1"; shift
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [[ $rc -ne 0 ]]; then
  echo "::error title=$title::$(tail -n 60 "$log" | perl -pe 's/%/%25/g; s/\r/%0D/g; s/\n/%0A/g')"
fi
exit "$rc"
