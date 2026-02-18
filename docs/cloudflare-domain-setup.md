# Konfiguracja domeny z Cloudflare

Ten poradnik pokazuje jak przenieść domenę (np. z OVH) pod Cloudflare, żeby móc korzystać z automatyzacji DNS w StackPilot.

## Dlaczego Cloudflare?

1. **Mikrus używa IPv6** - większość polskich ISP nie obsługuje IPv6. Cloudflare działa jako "tłumacz" (proxy) między IPv4 a IPv6.
2. **Automatyzacja DNS** - nasz skrypt `dns-add.sh` automatycznie dodaje rekordy DNS przez API.
3. **Darmowy SSL** - Cloudflare zapewnia certyfikaty SSL bez konfiguracji.
4. **Ochrona DDoS** - darmowa podstawowa ochrona przed atakami.
5. **CDN** - szybsze ładowanie strony dla użytkowników.

## Krok 1: Kup domenę

Jeśli nie masz jeszcze domeny, polecamy **OVH** - uczciwe ceny bez haczyków:

👉 [**Kup domenę w OVH**](https://www.ovhcloud.com/pl/domains/)

> 💡 **Dlaczego OVH?**
> - Odnowienie domeny `.pl`: **~59 zł/rok** (netto)
> - Dla porównania: home.pl i nazwa.pl to **169-200 zł/rok** za odnowienie!
> - Kuszą promocją "domena za 1 zł" ale potem 3-4x drożej
> - OVH ma uczciwe ceny od startu - bez pułapek
>
> Źródło: [Ranking rejestratorów 2025](https://nawitrynie.pl/gdzie-sa-najtansze-domeny-ranking-rejestratorow-domen-ceny-rejestracji-i-odnowienia/)

## Krok 2: Załóż darmowe konto Cloudflare

1. Wejdź na [cloudflare.com](https://www.cloudflare.com/) i kliknij "Sign Up"
2. Podaj email i hasło
3. Plan wybierz **Free** (darmowy)

> 💡 **Darmowy plan naprawdę wystarcza!**
> - Nielimitowana liczba domen
> - Pełne API do automatyzacji DNS
> - SSL/HTTPS dla wszystkich domen
> - CDN i ochrona DDoS
> - Brak limitów ruchu
>
> Płatne plany ($20+/mies) są dla dużych firm z milionami odwiedzin. Dla Mikrusa i małego biznesu **Free = wszystko czego potrzebujesz**.

## Krok 3: Dodaj domenę do Cloudflare

1. Po zalogowaniu kliknij **"Add a Site"**
2. Wpisz swoją domenę (np. `mojafirma.pl`) - bez `www`!
3. Wybierz plan **Free**
4. Cloudflare przeskanuje istniejące rekordy DNS

## Krok 4: Zmień serwery DNS w OVH

Cloudflare pokaże Ci dwa serwery nazw (nameservers), np.:
```
aria.ns.cloudflare.com
brett.ns.cloudflare.com
```

Teraz musisz je ustawić w OVH:

### W panelu OVH:

1. Zaloguj się do [OVH Manager](https://www.ovh.com/manager/)
2. Przejdź do **Web Cloud** → **Domeny** → wybierz swoją domenę
3. Kliknij zakładkę **"Serwery DNS"**
4. Kliknij **"Zmień serwery DNS"**
5. Wybierz **"Wpisz własne serwery DNS"**
6. Wpisz serwery od Cloudflare:
   - Serwer DNS 1: `aria.ns.cloudflare.com` (Twój będzie inny!)
   - Serwer DNS 2: `brett.ns.cloudflare.com`
7. Kliknij **"Zastosuj"**

> ⏳ **Uwaga:** Zmiana serwerów DNS może zająć do 24-48 godzin, ale zazwyczaj działa w ciągu 1-2 godzin.

## Krok 5: Potwierdź w Cloudflare

1. Wróć do Cloudflare
2. Kliknij **"Check nameservers"**
3. Gdy serwery się przepiszą, zobaczysz status **"Active"**

## Krok 6: Skonfiguruj SSL w Cloudflare

1. W Cloudflare przejdź do **SSL/TLS** → **Overview**
2. Ustaw tryb na **"Full"** (nie "Flexible"!)

> ⚠️ **Ważne:** Tryb "Flexible" może powodować pętle przekierowań z Caddy. Użyj "Full".

## Krok 7: Skonfiguruj automatyzację w StackPilot

Teraz możesz skonfigurować automatyczne dodawanie rekordów DNS:

```bash
cd stackpilot
./local/setup-cloudflare.sh
```

Skrypt:
1. Otworzy przeglądarkę na stronie tworzenia API tokenu
2. Stwórz token z uprawnieniem "Edit zone DNS"
3. Wklej token w terminalu
4. Gotowe!

## Użycie

Teraz dodawanie domeny to jedno polecenie:

```bash
# Dodaj rekord DNS (IPv6 pobierze się automatycznie!)
./local/dns-add.sh status.mojafirma.pl mikrus

# Wystaw aplikację przez HTTPS
ssh mikrus 'sp-expose status.mojafirma.pl 3001'
```

## Weryfikacja

Sprawdź czy domena działa:

```bash
# Sprawdź DNS
ping status.mojafirma.pl

# Sprawdź HTTPS
curl -I https://status.mojafirma.pl
```

## Rozwiązywanie problemów

### "DNS not propagated yet"
Poczekaj 5-10 minut. Cloudflare jest szybki, ale propagacja może chwilę zająć.

### "SSL certificate error"
1. Sprawdź czy w Cloudflare jest tryb SSL "Full" (nie "Flexible")
2. Sprawdź czy proxy jest włączony (żółta chmurka przy rekordzie)

### "502 Bad Gateway"
1. Sprawdź czy aplikacja działa: `ssh mikrus 'docker ps'`
2. Sprawdź czy port jest poprawny w `sp-expose`

### "Connection refused"
1. Upewnij się że Caddy jest zainstalowany: `ssh mikrus 'which caddy'`
2. Sprawdź status Caddy: `ssh mikrus 'systemctl status caddy'`

---

## Inne rejestratory domen

### home.pl
1. Zaloguj się do [Panel Klienta](https://home.pl/panel/)
2. Wybierz domenę → **Zarządzanie DNS**
3. Zmień serwery DNS na te z Cloudflare

### nazwa.pl
1. Zaloguj się do [Panelu](https://nazwa.pl/panel/)
2. Domeny → wybierz domenę → **Serwery DNS**
3. Ustaw własne serwery DNS

### Cloudflare Registrar (opcja zaawansowana)
Możesz też przenieść całą domenę do Cloudflare Registrar - wtedy masz wszystko w jednym miejscu i często taniej. Opcja dostępna w Cloudflare → Domain Registration → Transfer Domains.
