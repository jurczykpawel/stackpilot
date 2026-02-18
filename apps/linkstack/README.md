# 🔗 LinkStack - Wizytówka (Wersja Admin)

Twoja własna strona "Link in Bio" (jak Linktree), ale na Twoim serwerze.

**RAM:** ~200MB | **Dysk:** ~600MB | **Plan:** Mikrus 2.1+

## 🚀 Instalacja

```bash
# Cytrus (domena *.byst.re)
./local/deploy.sh linkstack --ssh=mikrus --domain-type=cytrus --domain=links.byst.re --yes

# Cloudflare (własna domena)
./local/deploy.sh linkstack --ssh=mikrus --domain-type=cloudflare --domain=links.mojafirma.pl --yes

# Bez domeny (dostęp przez tunel SSH)
./local/deploy.sh linkstack --ssh=mikrus --domain-type=local --yes
```

## ⚙️ Konfiguracja (Setup Wizard)

Po instalacji otwórz URL i przejdź przez wizard. **Ważny wybór:**

### Baza danych

**🎯 Jesteś soloprenerem / robisz stronę dla siebie?**

Wybierz **SQLite** i nie myśl więcej. Zero konfiguracji, działa od razu.

**🏢 Robisz to dla firmy gdzie wiele osób będzie edytować profile?**

Wybierz **MySQL** - lepiej radzi sobie gdy kilka osób edytuje jednocześnie.

<details>
<summary>Szczegóły techniczne</summary>

| Scenariusz | Rekomendacja |
|------------|--------------|
| Jeden profil (personal branding) | SQLite ✅ |
| Kilka profili, sporadyczne edycje | SQLite ✅ |
| 500+ użytkowników z własnymi profilami | MySQL |
| Częste jednoczesne edycje | MySQL |

SQLite obsługuje do 100K wizyt/dzień. Oficjalny hosting LinkStack używa MySQL dopiero dla instancji 500+ użytkowników.

> ℹ️ Przy MySQL musisz sam backupować bazę (przy SQLite backup przed aktualizacją zawiera bazę automatycznie).

</details>

<details>
<summary>Konfiguracja MySQL</summary>

1. Aktywuj w panelu: https://mikr.us/panel/?a=mysql
2. Pobierz dane:
   ```bash
   ssh mikrus 'curl -s -d "srv=$(hostname)&key=$(cat /klucz_api)" https://api.mikr.us/db.bash'
   ```
3. W wizardzie wybierz MySQL i wpisz dane z sekcji `mysql=`

</details>

### Pozostałe ustawienia

- **Admin credentials** - zapisz bezpiecznie, będziesz ich potrzebować do logowania
- **App Name** - nazwa wyświetlana na stronie
- **App URL** - pełny URL z https:// (np. `https://links.byst.re`)

## 🆚 LinkStack vs LittleLink

| Cecha | LinkStack | LittleLink |
|-------|-----------|------------|
| Panel admina | ✅ Tak | ❌ Nie |
| Edycja z telefonu | ✅ Tak | ❌ Nie |
| Statystyki kliknięć | ✅ Tak | ❌ Nie |
| Zużycie RAM | ~200MB | ~30MB |
| Konfiguracja | Wizard | Edycja HTML |

**Wybierz LinkStack** jeśli chcesz wygodny panel i statystyki.
**Wybierz LittleLink** jeśli wolisz super-lekką stronę statyczną.

## 📁 Lokalizacja danych

```
/opt/stacks/linkstack/
├── data/              # Wszystkie dane aplikacji (backupuj ten folder!)
│   ├── database/      # SQLite baza danych
│   ├── .env           # Konfiguracja
│   └── ...            # Pliki aplikacji
└── docker-compose.yaml
```

## 🔧 Zarządzanie

```bash
# Logi
ssh mikrus "docker logs -f linkstack-linkstack-1"

# Restart
ssh mikrus "cd /opt/stacks/linkstack && docker compose restart"

# Aktualizacja
ssh mikrus "cd /opt/stacks/linkstack && docker compose pull && docker compose up -d"

# Backup
ssh mikrus "tar -czf linkstack-backup.tar.gz -C /opt/stacks/linkstack data"
```

## 🔗 Przydatne linki

- [LinkStack Docker](https://linkstack.org/docker/)
- [LinkStack Docs](https://docs.linkstack.org/)
