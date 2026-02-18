# Vaultwarden - Sejf na hasla

Lekki serwer Bitwarden napisany w Rust. Twoje hasla do wszystkich uslug w jednym, bezpiecznym miejscu na Twoim serwerze.

## Dlaczego Vaultwarden, a nie Bitwarden?

Oficjalny serwer Bitwarden wymaga 2-4 GB RAM (8+ kontenerow: .NET, MSSQL, Nginx, Identity, API, Admin...). Na Mikrusie z 1 GB RAM nawet by nie wystartowal.

| | Vaultwarden | Bitwarden oficjalny |
|---|---|---|
| RAM | ~50 MB | 2-4 GB |
| Kontenery | 1 | 8+ |
| Baza danych | SQLite | MSSQL |
| Klienty Bitwarden | 100% kompatybilny | natywne |
| Premium features | wszystkie za darmo | wymagana licencja |
| Jezyk | Rust | .NET (C#) |

## Instalacja

```bash
./local/deploy.sh vaultwarden --ssh=mikrus --domain-type=cytrus --domain=auto
```

## Wymagania

- **RAM:** ~50MB (Rust, bardzo lekki)
- **Dysk:** ~330MB (obraz Docker)
- **Baza danych:** SQLite (wbudowany, zero konfiguracji)
- **Port:** 8088

## HTTPS jest OBOWIAZKOWY

Vaultwarden przechowuje hasla — **nigdy nie uzywaj go bez HTTPS!**
Bez szyfrowania TLS hasla sa przesylane czystym tekstem. Zawsze uzywaj domeny z certyfikatem SSL (Cytrus lub Cloudflare).

Tryb `--domain-type=local` (tunel SSH) jest bezpieczny lokalnie, ale nie udostepniaj Vaultwarden publicznie bez HTTPS.

## Po instalacji

1. **Zarejestruj sie natychmiast** po uruchomieniu uslugi — pierwsze konto zostaje adminem
2. **Wylacz rejestracje** dla innych, aby nikt obcy nie mogl zalozyc konta:
   ```bash
   ssh mikrus 'cd /opt/stacks/vaultwarden && sed -i "s/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/" docker-compose.yaml && docker compose up -d'
   ```
3. **Panel admina** — token zapisany w `/opt/stacks/vaultwarden/.admin_token`:
   ```bash
   ssh mikrus 'cat /opt/stacks/vaultwarden/.admin_token'
   ```
   Dostep: `https://twoja-domena.byst.re/admin`
4. Uzywaj aplikacji mobilnej i wtyczki przegladarkowej **Bitwarden** — sa w pelni kompatybilne z Vaultwarden

## Backup

Dane w `/opt/stacks/vaultwarden/data/` (SQLite + zalaczniki). Wystarczy backup tego katalogu.
