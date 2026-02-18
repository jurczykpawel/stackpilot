# Gotenberg

API do konwersji dokumentów. Lekka alternatywa dla Stirling-PDF.

> ⚠️ **Gotenberg nie ma interfejsu graficznego!** To czyste API.
> Po wejściu na domenę zobaczysz: *"Hey, Gotenberg has no UI, it's an API."*
> Używasz go przez HTTP requesty (curl, n8n, własna aplikacja).

## Porównanie ze Stirling-PDF

| Cecha | Gotenberg | Stirling-PDF |
|-------|-----------|--------------|
| RAM | ~150MB | ~450MB |
| Technologia | Go | Java (Spring Boot) |
| Interfejs | Tylko API | Web UI + API |
| Mikrus 2.1 | ✅ Działa | ❌ Za ciężki |

## Kiedy wybrać Gotenberg?

- Potrzebujesz tylko API (bez UI)
- Masz Mikrus 2.1 (1GB RAM)
- Integrujesz z n8n, Make, czy własną aplikacją
- Generujesz PDF-y automatycznie (faktury, raporty, certyfikaty)

## Kiedy wybrać Stirling-PDF?

- Chcesz wygodny interfejs webowy (klikasz, przeciągasz pliki)
- Masz Mikrus 3.0+ (2GB RAM)
- Potrzebujesz zaawansowanych funkcji (OCR, watermark, podpis cyfrowy)

## Obsługiwane konwersje

- HTML → PDF (przez Chromium)
- Markdown → PDF
- DOCX, XLSX, PPTX, ODT → PDF (przez LibreOffice)
- Łączenie wielu PDF w jeden
- Konwersja URL → PDF (screenshot strony)

---

## Przykłady użycia (curl)

### 1. Strona WWW → PDF
```bash
curl -X POST https://TWOJA-DOMENA.byst.re/forms/chromium/convert/url \
  -F 'url=https://example.com' \
  -o strona.pdf
```

### 2. HTML → PDF (generowanie faktury)
```bash
# Utwórz plik HTML
cat > faktura.html << 'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Faktura</title></head>
<body>
  <h1>Faktura #123</h1>
  <p>Data: 2026-01-11</p>
  <table border="1">
    <tr><th>Usługa</th><th>Cena</th></tr>
    <tr><td>Konsultacja</td><td>500 zł</td></tr>
  </table>
  <p><strong>Razem: 500 zł</strong></p>
</body>
</html>
EOF

# Konwertuj do PDF
curl -X POST https://TWOJA-DOMENA.byst.re/forms/chromium/convert/html \
  -F 'files=@faktura.html' \
  -o faktura.pdf
```

### 3. DOCX → PDF
```bash
curl -X POST https://TWOJA-DOMENA.byst.re/forms/libreoffice/convert \
  -F 'files=@dokument.docx' \
  -o dokument.pdf
```

### 4. Excel → PDF
```bash
curl -X POST https://TWOJA-DOMENA.byst.re/forms/libreoffice/convert \
  -F 'files=@raport.xlsx' \
  -o raport.pdf
```

### 5. Łączenie PDF-ów
```bash
curl -X POST https://TWOJA-DOMENA.byst.re/forms/pdfengines/merge \
  -F 'files=@plik1.pdf' \
  -F 'files=@plik2.pdf' \
  -F 'files=@plik3.pdf' \
  -o polaczony.pdf
```

### 6. Test czy działa (health check)
```bash
curl https://TWOJA-DOMENA.byst.re/health
# Powinno zwrócić: {"status":"up"}
```

---

## Integracja z n8n

### Generowanie PDF z HTML

1. **HTTP Request** node:
   - Method: `POST`
   - URL: `http://gotenberg:3000/forms/chromium/convert/html`
   - Body Content Type: `Form-Data`
   - Form Parameters:
     - Name: `files`
     - Value: `{{ $json.htmlContent }}`  (lub plik binarny)

2. **Zapisz wynik** - output to binarny PDF

### Screenshot strony WWW

1. **HTTP Request** node:
   - Method: `POST`
   - URL: `http://gotenberg:3000/forms/chromium/convert/url`
   - Body Content Type: `Form-Data`
   - Form Parameters:
     - Name: `url`
     - Value: `https://example.com`

### Typowe use-cases w n8n:
- Automatyczne generowanie faktur po płatności (Stripe webhook → HTML → PDF → email)
- Raporty tygodniowe (dane z bazy → HTML template → PDF)
- Archiwizacja stron WWW jako PDF
- Konwersja dokumentów uploadowanych przez klientów

---

## Opcje API

### Ustawienia strony (Chromium)
```bash
curl -X POST http://localhost:3000/forms/chromium/convert/html \
  -F 'files=@index.html' \
  -F 'paperWidth=8.5' \
  -F 'paperHeight=11' \
  -F 'marginTop=0.5' \
  -F 'marginBottom=0.5' \
  -F 'landscape=true' \
  -o result.pdf
```

### Czekaj na załadowanie JS (SPA)
```bash
curl -X POST http://localhost:3000/forms/chromium/convert/url \
  -F 'url=https://spa-app.com' \
  -F 'waitDelay=3s' \
  -o result.pdf
```

---

## Dokumentacja

- [Gotenberg Docs](https://gotenberg.dev/docs/getting-started)
- [API Routes](https://gotenberg.dev/docs/routes)
- [Chromium options](https://gotenberg.dev/docs/routes#chromium)
- [LibreOffice options](https://gotenberg.dev/docs/routes#libreoffice)
