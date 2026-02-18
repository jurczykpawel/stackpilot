# 🤖 Typebot - Chatboty i Formularze

Typebot to wizualny kreator chatbotów, który zastępuje drogie narzędzia typu Typeform.

## 🚀 Instalacja

```bash
./local/deploy.sh typebot
```

## 🔗 Integracja "Lazy Engineer"
Typebot to "wejście" do Twojego systemu. 
1. Klient wypełnia bota.
2. Bot wysyła dane do **n8n** przez webhooka.
3. n8n zapisuje dane w **NocoDB** i wysyła ofertę przez **Listmonka**.

## 📋 Wymagania

- **RAM:** ~600MB (Builder + Viewer)
- **Dysk:** ~3GB (2x obraz Next.js)
- **Baza danych:** PostgreSQL (dedykowana — shared Mikrus nie działa, PG 12 nie ma `gen_random_uuid()`)

> ⚠️ **Współdzielona baza Mikrusa NIE działa!** Typebot używa Prisma, które wymaga `gen_random_uuid()` — niedostępne na shared PostgreSQL 12. Potrzebujesz dedykowanej bazy (29 zł/rok): [Panel Mikrus → Cloud](https://mikr.us/panel/?a=cloud)

## ⚠️ Uwaga o zasobach
Typebot składa się z dwóch części: Buildera (do tworzenia) i Viewera (to co widzi klient). Oba potrzebują łącznie ok. 600MB RAM, więc miej to na uwadze przy planowaniu usług na jednym Mikrusie.