# Failover-Test

Zwischen den Nodes proxy01 (MASTER) und proxy02 (BACKUP) muss VRRP zuverlässig switchen. Hier ein paar Szenarien zum Testen — am besten direkt nach dem Initial-Setup, bevor echte Services drauf liegen.

## Szenario 1: nginx-Crash auf MASTER

```bash
# Aktueller Zustand
ssh root@proxy01 "ip -4 addr show | grep $(grep FLOATING_IP /etc/proxy-config/values.env | cut -d= -f2 | cut -d/ -f1)"
# → sollte die Floating-IP zeigen

# Auf MASTER nginx stoppen
ssh root@proxy01 "systemctl stop nginx"

# Nach ~4 Sekunden (2x check-interval) sollte BACKUP übernehmen
sleep 5
ssh root@proxy02 "ip -4 addr show | grep $(grep FLOATING_IP /etc/proxy-config/values.env | cut -d= -f2 | cut -d/ -f1)"
# → jetzt auf proxy02

# nginx wieder starten
ssh root@proxy01 "systemctl start nginx"
sleep 5
# MASTER hat höhere Priorität → sollte zurückkommen
```

## Szenario 2: Komplett-Ausfall MASTER

```bash
# proxy01 herunterfahren
ssh root@proxy01 "shutdown -h now"

# Beobachten — sollte sofort umschwenken
ssh root@proxy02 "journalctl -u keepalived -f"

# Floating-IP testen (von extern)
curl -I https://<eine-deiner-domains>/
# muss weiter funktionieren

# proxy01 wieder hochfahren
# → kommt zurück als MASTER (Default ohne nopreempt)
```

## Szenario 3: Netzwerk-Trennung

Im Proxmox-Webinterface die Netzwerkkarte von proxy01 deaktivieren. Selbe Wirkung wie Szenario 2, testet aber den Pfad ohne sauberes Shutdown.

## Was protokolliert werden sollte

Auf beiden Nodes:

```bash
journalctl -u keepalived --since "10 min ago"
cat /var/log/keepalived-state.log
```

Du solltest Einträge wie `Entering MASTER STATE` / `Entering BACKUP STATE` sehen.

## Auf der Statusseite sichtbar

- "Cluster-Rolle" wechselt zwischen MASTER und BACKUP
- "Letzter Wechsel"-Timestamp aktualisiert sich
- Peer-Block zeigt jeweils die Gegen-Rolle

## Failover-Geschwindigkeit

Mit den Defaults dieses Repos:
- VRRP-Advertisement: 1 Sekunde
- Health-Check-Intervall: 2 Sekunden, fall=2
- Gratuitous ARP nach State-Change

→ erwartet: ~3-5 Sekunden Ausfall bis BACKUP übernimmt.

Wenn du das schneller willst: `advert_int 1` → `advert_int 1; ` und Health-Check auf 1 Sekunde mit `fall 1`. Vorsicht — zu aggressiv kann Flapping bei kurzen Lastspitzen auslösen.

## Troubleshooting

**Floating-IP wird nicht übernommen:**
- Multicast 224.0.0.18 zwischen den Nodes geblockt? (`tcpdump -i eth0 vrrp`)
- `virtual_router_id` und `auth_pass` auf beiden Nodes identisch?
- Interface-Name in keepalived.conf korrekt?

**Beide Nodes denken sie sind MASTER:**
- VRRP-Pakete kommen nicht durch (Firewall, Switch-Filter)
- → Split-Brain mit doppelter IP — sehr kurz tolerabel, dauerhaft Problem

**Floating-IP "klebt" an alter MASTER:**
- ARP-Cache der Clients/Switches
- Gratuitous ARP kommt automatisch, aber managed Switches mit DAI können das blocken

## Kommando-Zusammenfassung

```bash
# Wer ist MASTER?
for h in proxy01 proxy02; do
  echo -n "$h: "; ssh root@$h "cat /run/keepalived-state 2>/dev/null || echo UNKNOWN"
done

# Live-Log VRRP
ssh root@proxy01 "tcpdump -i eth0 -n vrrp"
```
