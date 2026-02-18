# 📊 Umami - Analityka bez szpiegowania

Prosta, szybka i prywatna alternatywa dla Google Analytics. Zgodna z RODO bez uciążliwych banerów cookie.

## 🚀 Instalacja

```bash
./local/deploy.sh umami
```

**Wymagania:**
- PostgreSQL z rozszerzeniem **pgcrypto**
- ⚠️ **Współdzielona baza Mikrusa NIE działa!** (brak uprawnień do tworzenia rozszerzeń)
- Użyj: dedykowany PostgreSQL z [Mikrus Cloud](https://mikr.us/panel/?a=cloud) (od 5 PLN/mies.)

## 💡 Dlaczego warto?
- **Masz własność danych:** Google nie sprzedaje Twoich statystyk reklamodawcom.
- **Lekkość:** Skrypt śledzący waży < 2KB. Twoja strona ładuje się szybciej.
- **Współdzielenie:** Możesz wygenerować publiczny link do statystyk dla klienta.

## ☁️ Opcja "Smart Saver" (Oszczędzaj RAM)
Jeśli Twój Mikrus ma mało pamięci (np. 1GB), rozważ wykupienie **Umami jako oddzielnej usługi w chmurze Mikrusa**.
Zyskasz:
- Więcej RAM-u na swoim serwerze dla n8n.
- Gotową, skonfigurowaną usługę bez potrzeby zarządzania bazą danych.
- Sprawdź ofertę w panelu Mikrusa w sekcji "Usługi dodatkowe".
