#!/bin/sh
# Holt das WLAN des Pi zurück, wenn es ausfällt. Läuft als root etwa einmal pro Minute
# (miniply-wlan-waechter.timer) und merkt sich die Fehlversuche in Folge.
# Nach 3 Minuten verbindet er das WLAN neu, nach 6 Minuten lädt er den Treiber neu,
# danach alle 10 Minuten wieder. Den Pi selbst startet er nie neu.
# Außerdem hält er das Energiesparen des WLAN-Chips aus: Damit bremst der Treiber (brcmfmac)
# das WLAN des Pi stark und verliert die Verbindung öfter; nach einem Treiber-Neustart ist es wieder an.
set -u

ZUSTAND=${WLAN_ZUSTAND:-/run/miniply-wlan}
GERAET=wlan0
VPS=10.77.0.1
ZAEHLER="$ZUSTAND/fehlversuche"

antwortet() {
    ping -c 3 -W 2 "$1" >/dev/null 2>&1
}

# Solange der VPS antwortet, ist die Verbindung in Ordnung, auch wenn der Router Pings ignoriert.
verbindung_steht() {
    router=$(ip -4 route show default | awk '$2 == "via" { print $3; exit }')
    { [ -n "$router" ] && antwortet "$router"; } || antwortet "$VPS"
}

# Der Grund des Ausfalls stand bisher nirgends: Der Zustand landet im Journal.
zustand_festhalten() {
    ip -br addr
    ip -4 route
    wpa_cli -i "$GERAET" status 2>&1 | grep '^wpa_state='
    dmesg 2>&1 | grep -iE 'brcm|wlan0|mmc1' | tail -n 20
}

neu_verbinden() {
    timeout 30 systemctl restart "netplan-wpa-$GERAET.service" || echo "WLAN-Anmeldung ließ sich nicht neu starten"
    timeout 30 networkctl reconfigure "$GERAET" || echo "Adresse ließ sich nicht neu anfordern"
}

treiber_neu_laden() {
    if timeout 30 modprobe -r brcmfmac_wcc brcmfmac && timeout 30 modprobe brcmfmac; then
        stromsparen_aus
        neu_verbinden
    else
        echo "Treiber ließ sich nicht neu laden. Vielleicht hängt der WLAN-Chip, dann hilft nur ein Neustart des Pi."
    fi
}

# Braucht das Paket iw (apt install iw); ohne bleibt alles andere gleich.
stromsparen_aus() {
    command -v iw >/dev/null 2>&1 || return 0
    if iw dev "$GERAET" get power_save 2>/dev/null | grep -q ': on'; then
        iw dev "$GERAET" set power_save off && echo "Energiesparen des WLAN ausgeschaltet."
    fi
}

mkdir -p "$ZUSTAND"
stromsparen_aus
bisher=$(cat "$ZAEHLER" 2>/dev/null || echo 0)

if verbindung_steht; then
    if [ "$bisher" -gt 0 ]; then
        # Auch kurze Aussetzer festhalten: Sonst lässt sich ein Ausfall später nicht einordnen.
        echo "WLAN ist wieder da, nach $bisher Fehlversuchen."
        rm -f "$ZAEHLER"
    fi
    exit 0
fi

jetzt=$((bisher + 1))
# Zuerst speichern: Auch wenn ein Schritt hängen bleibt, geht die Zählung weiter.
echo "$jetzt" > "$ZAEHLER"

if [ "$jetzt" -eq 3 ]; then
    echo "Weder Router noch VPS antworten seit $jetzt Versuchen. WLAN wird neu verbunden."
    zustand_festhalten
    neu_verbinden
elif [ "$jetzt" -ge 6 ] && [ $(((jetzt - 6) % 10)) -eq 0 ]; then
    echo "Noch immer keine Verbindung nach $jetzt Versuchen. WLAN-Treiber wird neu geladen."
    zustand_festhalten
    treiber_neu_laden
fi
exit 0
