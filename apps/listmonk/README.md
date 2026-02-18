# 📧 Listmonk - Twój system newsletterowy

**Alternatywa dla Mailchimp / MailerLite / ActiveCampaign.**
Wysyłaj maile do tysięcy subskrybentów bez miesięcznych opłat za bazę.

> 🔗 **Oficjalna strona:** https://listmonk.app

---

## 💸 Dlaczego Listmonk?

| | Mailchimp | MailerLite | **Listmonk** |
|---|---|---|---|
| 1000 subskrybentów | 0 zł | 0 zł | **0 zł** |
| 10 000 subskrybentów | ~200 zł/mies | ~100 zł/mies | **0 zł** |
| 50 000 subskrybentów | ~800 zł/mies | ~300 zł/mies | **0 zł** |

Płacisz tylko za hosting (~16 zł/mies) i wysyłkę maili przez SMTP (np. Amazon SES: ~$1 za 10 000 maili).

---

## 📋 Wymagania

### PostgreSQL (obowiązkowe)

Listmonk wymaga bazy PostgreSQL z rozszerzeniem **pgcrypto** (od v6.0.0).

> ⚠️ **Współdzielona baza Mikrusa NIE działa!** Brak uprawnień do tworzenia rozszerzeń. Potrzebujesz dedykowanej bazy.

#### Dedykowana baza PostgreSQL

Zamów w [Panel Mikrus → Cloud](https://mikr.us/panel/?a=cloud):

| RAM | Dysk | Połączenia | Cena/rok |
|---|---|---|---|
| 512 MB | 10 GB | 100 | **29 zł** |
| 1024 MB | 50 GB | 100 | 119 zł |

👉 [Kup bazę w Panel Mikrus → Cloud](https://mikr.us/panel/?a=cloud)

> 💡 **Rekomendacja:** Baza 10GB za 29 zł/rok wystarczy na lata. Koszt minimalny, a masz pewność że dane są bezpieczne i nie dzielisz zasobów z innymi.

---

## 🚀 Instalacja

### Krok 1: Przygotuj dane do bazy

Z panelu Mikrusa (opcja A lub B powyżej) potrzebujesz:
- **Host** - np. `srv34.mikr.us` lub adres z chmury
- **Database** - nazwa bazy
- **User** - nazwa użytkownika
- **Password** - hasło

### Krok 2: Uruchom instalator

```bash
./local/deploy.sh listmonk
```

Skrypt zapyta o:
- Dane bazy PostgreSQL (host, database, user, password)
- Domenę (np. `newsletter.mojafirma.pl`)

### Krok 3: Skonfiguruj domenę

Po instalacji wystaw aplikację przez HTTPS:

**Caddy:**
```bash
mikrus-expose newsletter.mojafirma.pl 9000
```

**Cytrus:** Panel Mikrus → Domeny → przekieruj na port 9000

### Krok 4: Zaloguj się i skonfiguruj SMTP

1. Wejdź na `https://newsletter.mojafirma.pl`
2. Zaloguj się: **admin** / **listmonk**
3. **Zmień hasło!**
4. Idź do Settings → SMTP i skonfiguruj serwer mailowy

---

## 📬 Konfiguracja SMTP

Listmonk sam nie wysyła maili - potrzebujesz serwera SMTP:

| Usługa | Koszt | Limit |
|---|---|---|
| **Amazon SES** | ~$1 / 10 000 maili | Praktycznie bez limitu |
| **Mailgun** | $0 (3 mies.) potem $35/mies | 5000/mies free |
| **Resend** | $0 | 3000/mies free |
| **Własny serwer** | 0 zł | Ryzyko blacklisty |

> 💡 **Rekomendacja:** Amazon SES - najtańszy przy skali, wymaga weryfikacji domeny.

---

## 🔗 Integracja z n8n

Po zakupie w GateFlow lub rozmowie w Typebocie możesz automatycznie dodawać osoby do Listmonka.

**Przykład workflow n8n:**
```
[Webhook z GateFlow] → [HTTP Request do Listmonk API] → [Dodaj do listy "Klienci"]
```

Listmonk API: `https://listmonk.app/docs/apis/subscribers/`

---

## ❓ FAQ

**Q: Ile RAM-u zużywa Listmonk?**
A: ~50-100MB. Napisany w Go, bardzo lekki.

**Q: Mogę importować subskrybentów z Mailchimp?**
A: Tak! Eksportuj CSV z Mailchimp i zaimportuj w Listmonk → Subscribers → Import.

**Q: Jak uniknąć spamu?**
A: Skonfiguruj SPF, DKIM i DMARC dla swojej domeny. Listmonk ma wbudowaną obsługę double opt-in.
