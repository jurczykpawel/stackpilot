# 📈 Uptime Kuma - Twój Stróż Nocny

Piękny i prosty dashboard do monitoringu. Zastępuje płatnego UptimeRobota.

## 🚀 Instalacja

```bash
./local/deploy.sh uptime-kuma
```

## 💡 Zastosowanie w biznesie
Twoje automatyzacje w n8n muszą działać 24/7. Ale skąd wiesz, czy działają?
1. Skonfiguruj Uptime Kuma, aby sprawdzał Twoje webhooki n8n lub stronę GateFlow co minutę.
2. Podepnij powiadomienia (np. do **ntfy** lub na Telegram).
3. Śpij spokojnie. Jak coś padnie, telefon Cię obudzi.

## 🌐 Po instalacji - konfiguracja domeny

### 1. Skonfiguruj DNS
Dodaj rekord A w panelu swojego rejestratora domen (np. OVH, Cloudflare, home.pl):
- **Typ:** `A`
- **Nazwa:** `status` (lub inna subdomena, np. `uptime`, `monitor`)
- **Wartość:** IP Twojego serwera Mikrus (znajdziesz w panelu mikr.us)
- **TTL:** 3600 (lub "Auto")

> ⏳ Propagacja DNS może zająć od kilku minut do 24h. Sprawdź: `ping status.twojadomena.pl`

### 2. Wystaw aplikację przez HTTPS
Uruchom **na swoim komputerze** (nie na serwerze!):
```bash
ssh mikrus 'mikrus-expose status.twojadomena.pl 3001'
```
Zamień `mikrus` na swój alias SSH jeśli używasz innego, oraz `status.twojadomena.pl` na swoją domenę.

### 3. Utwórz konto admina
Przy pierwszym wejściu na `https://status.twojadomena.pl` Uptime Kuma poprosi o utworzenie konta administratora. Zapisz dane logowania w bezpiecznym miejscu!

## ☁️ Opcja "Smart Saver" (Oszczędzaj RAM)
Jeśli Twój Mikrus ma mało pamięci (np. 1GB), możesz wykupić **Uptime Kuma jako oddzielną usługę w chmurze Mikrusa**.
Zyskasz:
- Zero obciążenia Twojego serwera monitoringiem.
- Większą wiarygodność monitoringu (jeśli Twój główny serwer padnie, Kuma działająca na innym serwerze od razu Cię powiadomi).
- Sprawdź ofertę w panelu Mikrusa w sekcji "Usługi dodatkowe".
