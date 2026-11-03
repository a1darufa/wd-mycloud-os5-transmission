#!/bin/sh
# preinst.sh <app folder> — run from the OLD version, only on upgrade.
# Refreshes the upgrade flag in case the new package's before_apkg.sh didn't.

. "$(dirname "$0")/lib.sh"

tr_prepare_home
date '+%Y-%m-%d %H:%M:%S' > "$TR_UPGRADING"
exit 0
