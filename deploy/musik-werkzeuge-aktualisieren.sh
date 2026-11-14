#!/bin/sh
# Bringt yt-dlp und Deno auf den neuesten Stand. Läuft auf dem Pi als root, einmal am Tag
# und sobald der Musik-Dienst nichts mehr laden kann (miniply-music-update.service).
# Beide kommen von ihren offiziellen GitHub-Seiten und werden per Prüfsumme geprüft.
# Geladen wird nur, was sich geändert hat. Eine neue Version ersetzt die alte erst,
# wenn sie sich starten lässt; bei jedem Fehler bleibt die alte einfach liegen.
set -eu
WERKZEUGE=${MUSIK_WERKZEUGE:-/usr/local/lib/miniply/tools}
YT=https://github.com/yt-dlp/yt-dlp/releases/latest/download
DENO=https://github.com/denoland/deno/releases/latest/download
DENO_ZIP=deno-aarch64-unknown-linux-gnu.zip

arbeit=$(mktemp -d)
trap 'rm -rf "$arbeit"' EXIT
chmod 0755 "$arbeit"
cd "$arbeit"
install -d -m 0755 "$WERKZEUGE"

# Der frisch geladene Stand läuft zum Testen nur mit den Rechten des Musik-Dienstes.
startet() {
    setpriv --reuid=miniply --regid=media --clear-groups \
        env HOME="$arbeit" TMPDIR="$arbeit" "$1" --version
}

curl -fsSLO "$YT/SHA2-256SUMS"
grep ' yt-dlp_linux_aarch64$' SHA2-256SUMS > yt-dlp.sha256
if cmp -s yt-dlp.sha256 "$WERKZEUGE/yt-dlp.sha256" && [ -x "$WERKZEUGE/yt-dlp" ]; then
    echo "yt-dlp ist aktuell."
else
    curl -fsSLO "$YT/yt-dlp_linux_aarch64"
    sha256sum -c yt-dlp.sha256
    chmod 0755 yt-dlp_linux_aarch64
    startet "$arbeit/yt-dlp_linux_aarch64"
    install -m 0755 yt-dlp_linux_aarch64 "$WERKZEUGE/yt-dlp.neu"
    mv "$WERKZEUGE/yt-dlp.neu" "$WERKZEUGE/yt-dlp"
    install -m 0644 yt-dlp.sha256 "$WERKZEUGE/yt-dlp.sha256"
    echo "yt-dlp wurde aktualisiert."
fi

curl -fsSLO "$DENO/$DENO_ZIP.sha256sum"
if cmp -s "$DENO_ZIP.sha256sum" "$WERKZEUGE/deno.sha256sum" && [ -x "$WERKZEUGE/deno" ]; then
    echo "Deno ist aktuell."
else
    curl -fsSLO "$DENO/$DENO_ZIP"
    sha256sum -c "$DENO_ZIP.sha256sum"
    python3 -I -m zipfile -e "$DENO_ZIP" .
    chmod 0755 deno
    startet "$arbeit/deno"
    install -m 0755 deno "$WERKZEUGE/deno.neu"
    mv "$WERKZEUGE/deno.neu" "$WERKZEUGE/deno"
    install -m 0644 "$DENO_ZIP.sha256sum" "$WERKZEUGE/deno.sha256sum"
    echo "Deno wurde aktualisiert."
fi
