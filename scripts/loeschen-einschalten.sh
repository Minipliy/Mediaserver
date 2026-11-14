#!/bin/sh
# Schaltet auf dem Raspberry Pi das Löschen aus der App ein (MINIPLY_DELETES=1).
# Vom Mac aus starten, nach scripts/update-pi.sh.
set -eu
ssh -t pi 'sudo sh -eu -c "
    grep -qs \"^ReadWritePaths=.*/mnt/media\" /etc/systemd/system/miniply.service.d/*.conf || {
        echo \"Der Server darf noch nicht in die Medien schreiben, siehe deploy/miniply-uploads.conf.\" >&2
        exit 1
    }
    sed -i /^MINIPLY_DELETES=/d /etc/miniply/server.env
    echo MINIPLY_DELETES=1 >> /etc/miniply/server.env
    systemctl restart miniply
    echo Das Löschen aus der App ist eingeschaltet.
"'
