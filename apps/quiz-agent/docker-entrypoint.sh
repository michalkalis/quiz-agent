#!/bin/sh
# #207 task 207.24: the app runs as the unprivileged `app` user. Fly mounts the
# volume at /data owned by root (and `fly ssh console` sessions write as
# root), so while still root, hand anything under /data not owned by `app`
# over to it, then drop privileges for the real command (uvicorn, or the
# release_command's `alembic upgrade head`, which runs without the volume).
set -e
if [ "$(id -u)" = "0" ]; then
    if [ -d /data ]; then
        find /data -xdev ! -user app -exec chown app:app {} +
    fi
    export HOME=/home/app
    exec setpriv --reuid=app --regid=app --init-groups -- "$@"
fi
exec "$@"
