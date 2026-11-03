#!/bin/sh
# clean.sh <app folder> — before remove.sh, and at shutdown. Removes the
# dashboard page links only.

. "$(dirname "$0")/lib.sh"

tr_unlink_web
exit 0
