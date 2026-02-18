# 🎬 Cap - Open Source Loom Alternative

**Cap** pozwala nagrywać ekran, edytować i udostępniać wideo w sekundy. Idealne do:
- Nagrywania tutoriali dla klientów
- Asynchronicznej komunikacji w zespole
- Prezentacji produktów
- Raportowania bugów z nagraniem ekranu

> 🔗 Strona projektu: https://cap.so
> 📦 GitHub: https://github.com/CapSoftware/Cap

---

## ⚠️ Wymagania

Cap jest **zasobożerny**. Wymaga:

| Komponent | Opis | RAM |
|-----------|------|-----|
| cap-web | Aplikacja główna | ~400-500 MB |
| MySQL | Baza danych | ~300-500 MB |
| MinIO | Storage S3 (opcjonalnie) | ~200 MB |

**Rekomendacja:** Mikrus 3.0 (2GB RAM) lub wyższy.

### Optymalizacja dla Mikrus

Aby zaoszczędzić zasoby:
1. **Wspólny serwer MySQL z Mikrus (zalecane!)** - nie marnuj RAM-u na lokalną bazę. W panelu Mikrus wybierz "Poproszę o nowe dane" dla współdzielonej bazy MySQL. Baza Cap przechowuje tylko metadane (użytkownicy, linki) - same wideo idą do S3, więc 200MB limitu w zupełności wystarczy.
2. **Zewnętrzny S3** - użyj Cloudflare R2 (tanie!), AWS S3 lub Backblaze B2 zamiast lokalnego MinIO

---

## 🚀 Instalacja

```bash
./local/deploy.sh cap
```

Skrypt zapyta o:
1. **Tryb bazy danych** - zewnętrzna MySQL (zalecane) lub lokalna
2. **Tryb storage** - zewnętrzny S3 (zalecane) lub lokalny MinIO
3. **Domenę** - np. `cap.mojafirma.pl`

---

## 📦 Zalecana konfiguracja Storage

### Opcja 1: MinIO z StackPilot (najprostsze)
Jeśli masz zainstalowane MinIO jako osobną aplikację:
```bash
# Najpierw zainstaluj MinIO
./local/deploy.sh minio --ssh=ALIAS

# Credentials znajdziesz w:
ssh ALIAS "cat /opt/stacks/minio/.env"

# Potem zainstaluj Cap z zewnętrznym S3
S3_ENDPOINT=http://minio:9000 \
S3_ACCESS_KEY=admin \
S3_SECRET_KEY=<hasło-z-minio> \
S3_BUCKET=cap-videos \
./local/deploy.sh cap --ssh=ALIAS
```

### Opcja 2: Cloudflare R2 (najtańsze dla dużych ilości)
- Darmowe 10GB/miesiąc
- Brak opłat za transfer wychodzący (egress)
- Endpoint: `https://<account-id>.r2.cloudflarestorage.com`
- Region: `auto`

### Opcja 3: AWS S3
- Pay-as-you-go
- Region: `eu-central-1` (Frankfurt) dla niskich latencji z Polski

### Opcja 4: Backblaze B2
- Tanie storage
- Kompatybilne z S3 API

### Opcja 5: Lokalny MinIO (wbudowany w Cap)
Jeśli potrzebujesz MinIO tylko dla Cap:
```bash
USE_LOCAL_MINIO=true ./local/deploy.sh cap --ssh=ALIAS
```
MinIO wystartuje jako kontener w tym samym stacku co Cap.

---

## 🖥️ Klient desktopowy

Cap ma aplikację desktopową do nagrywania:
- **macOS:** https://cap.so/download
- **Windows:** https://cap.so/download

Po zainstalowaniu self-hosted wersji, skonfiguruj w aplikacji swój własny serwer.

---

## 🔧 Zarządzanie

### Logi
```bash
ssh mikrus "docker logs -f cap-cap-web-1"
```

### Restart
```bash
ssh mikrus "cd /opt/stacks/cap && docker compose restart"
```

### Aktualizacja
```bash
ssh mikrus "cd /opt/stacks/cap && docker compose pull && docker compose up -d"
```

---

## 🛡️ Bezpieczeństwo

Po instalacji **koniecznie zapisz** wygenerowane klucze:
- `NEXTAUTH_SECRET` - do autentykacji użytkowników
- `DATABASE_ENCRYPTION_KEY` - do szyfrowania danych w bazie

Bez tych kluczy nie odzyskasz dostępu do danych po reinstalacji!

---

## ❓ FAQ

**Q: Ile miejsca na dysku potrzebuję?**
A: Zależy od ilości nagrań. 1 minuta wideo HD to ~50-100 MB. Dla wielu nagrań użyj zewnętrznego S3.

**Q: Czy mogę użyć PostgreSQL zamiast MySQL?**
A: Nie. Cap oficjalnie wspiera tylko MySQL 8.0.

**Q: Jak udostępnić nagranie?**
A: Po nagraniu w aplikacji desktopowej, Cap automatycznie uploaduje wideo na Twój serwer i generuje link do udostępnienia.
