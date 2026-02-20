# Gotenberg

API for document conversion. A lightweight alternative to Stirling-PDF.

> **Gotenberg has no graphical interface!** It is a pure API.
> When you visit the domain you will see: *"Hey, Gotenberg has no UI, it's an API."*
> You use it via HTTP requests (curl, n8n, your own application).

## Comparison with Stirling-PDF

| Feature | Gotenberg | Stirling-PDF |
|---------|-----------|--------------|
| RAM | ~150MB | ~450MB |
| Technology | Go | Java (Spring Boot) |
| Interface | API only | Web UI + API |
| 1GB RAM VPS | Works | Too heavy |

## When to choose Gotenberg?

- You only need an API (no UI)
- You have a 1GB RAM VPS
- Integrating with n8n, Make, or your own application
- Generating PDFs automatically (invoices, reports, certificates)

## When to choose Stirling-PDF?

- You want a convenient web interface (click, drag files)
- You have a 2GB+ RAM VPS
- You need advanced features (OCR, watermark, digital signature)

## Supported Conversions

- HTML to PDF (via Chromium)
- Markdown to PDF
- DOCX, XLSX, PPTX, ODT to PDF (via LibreOffice)
- Merging multiple PDFs into one
- URL to PDF (page screenshot)

---

## Usage Examples (curl)

### 1. Web Page to PDF
```bash
curl -X POST https://your-domain.com/forms/chromium/convert/url \
  -F 'url=https://example.com' \
  -o page.pdf
```

### 2. HTML to PDF (generating an invoice)
```bash
# Create an HTML file
cat > invoice.html << 'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Invoice</title></head>
<body>
  <h1>Invoice #123</h1>
  <p>Date: 2026-01-11</p>
  <table border="1">
    <tr><th>Service</th><th>Price</th></tr>
    <tr><td>Consultation</td><td>$500</td></tr>
  </table>
  <p><strong>Total: $500</strong></p>
</body>
</html>
EOF

# Convert to PDF
curl -X POST https://your-domain.com/forms/chromium/convert/html \
  -F 'files=@invoice.html' \
  -o invoice.pdf
```

### 3. DOCX to PDF
```bash
curl -X POST https://your-domain.com/forms/libreoffice/convert \
  -F 'files=@document.docx' \
  -o document.pdf
```

### 4. Excel to PDF
```bash
curl -X POST https://your-domain.com/forms/libreoffice/convert \
  -F 'files=@report.xlsx' \
  -o report.pdf
```

### 5. Merging PDFs
```bash
curl -X POST https://your-domain.com/forms/pdfengines/merge \
  -F 'files=@file1.pdf' \
  -F 'files=@file2.pdf' \
  -F 'files=@file3.pdf' \
  -o merged.pdf
```

### 6. Health check
```bash
curl https://your-domain.com/health
# Should return: {"status":"up"}
```

---

## Integration with n8n

### Generating PDF from HTML

1. **HTTP Request** node:
   - Method: `POST`
   - URL: `http://gotenberg:3000/forms/chromium/convert/html`
   - Body Content Type: `Form-Data`
   - Form Parameters:
     - Name: `files`
     - Value: `{{ $json.htmlContent }}`  (or binary file)

2. **Save result** - output is a binary PDF

### Web Page Screenshot

1. **HTTP Request** node:
   - Method: `POST`
   - URL: `http://gotenberg:3000/forms/chromium/convert/url`
   - Body Content Type: `Form-Data`
   - Form Parameters:
     - Name: `url`
     - Value: `https://example.com`

### Typical use cases in n8n:
- Automatic invoice generation after payment (Stripe webhook -> HTML -> PDF -> email)
- Weekly reports (data from DB -> HTML template -> PDF)
- Archiving web pages as PDF
- Converting documents uploaded by clients

---

## API Options

### Page settings (Chromium)
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

### Wait for JS to load (SPA)
```bash
curl -X POST http://localhost:3000/forms/chromium/convert/url \
  -F 'url=https://spa-app.com' \
  -F 'waitDelay=3s' \
  -o result.pdf
```

---

## Documentation

- [Gotenberg Docs](https://gotenberg.dev/docs/getting-started)
- [API Routes](https://gotenberg.dev/docs/routes)
- [Chromium options](https://gotenberg.dev/docs/routes#chromium)
- [LibreOffice options](https://gotenberg.dev/docs/routes#libreoffice)
