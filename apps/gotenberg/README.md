# Gotenberg - Document Conversion API

Lightweight HTTP API for converting documents to PDF (HTML, DOCX, XLSX, PPTX, URLs) via Chromium and LibreOffice.

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

---

## Installation

```bash
./local/deploy.sh gotenberg --ssh=ALIAS --domain-type=cloudflare --domain=pdf.example.com
# or local access only (SSH tunnel):
./local/deploy.sh gotenberg --ssh=ALIAS --domain-type=local --yes
```

---

## Requirements

- **RAM:** 256MB (limit set in docker-compose; ~150MB typical usage)
- **Disk:** ~1500MB image (gotenberg:8 includes LibreOffice + Chromium)
- **Port:** 3000 (default: `PORT=${PORT:-3000}`) — Note: port is bound to all interfaces (0.0.0.0) — access is protected by Basic Auth. Use with a domain for HTTPS.
- **Database:** None

---

## After Installation

The API is **always protected with Basic Auth** (configured automatically during install).

Retrieve your credentials:

```bash
ssh ALIAS 'cat /opt/stacks/gotenberg/.api_credentials'
```

Or read from the `.env` equivalent:

```bash
ssh ALIAS 'cat /opt/stacks/gotenberg/.api_credentials'
# Output: user:password
```

---

## Usage Examples (curl)

> **All requests require `-u user:password`** — Basic Auth is always enabled.

### 1. Health check

```bash
curl -u user:password https://your-domain.com/health
# Returns: {"status":"up"}
```

### 2. Web Page to PDF

```bash
curl -u user:password \
  -X POST https://your-domain.com/forms/chromium/convert/url \
  -F 'url=https://example.com' \
  -o page.pdf
```

### 3. HTML to PDF (generating an invoice)

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
curl -u user:password \
  -X POST https://your-domain.com/forms/chromium/convert/html \
  -F 'files=@invoice.html' \
  -o invoice.pdf
```

### 4. DOCX to PDF

```bash
curl -u user:password \
  -X POST https://your-domain.com/forms/libreoffice/convert \
  -F 'files=@document.docx' \
  -o document.pdf
```

### 5. Excel to PDF

```bash
curl -u user:password \
  -X POST https://your-domain.com/forms/libreoffice/convert \
  -F 'files=@report.xlsx' \
  -o report.pdf
```

### 6. Merging PDFs

```bash
curl -u user:password \
  -X POST https://your-domain.com/forms/pdfengines/merge \
  -F 'files=@file1.pdf' \
  -F 'files=@file2.pdf' \
  -F 'files=@file3.pdf' \
  -o merged.pdf
```

---

## Integration with n8n

In n8n use the **HTTP Request** node with **Basic Auth** credentials (add a credential of type "Basic Auth" with your Gotenberg user/password).

### Generating PDF from HTML

1. **HTTP Request** node:
   - Method: `POST`
   - URL: `https://gotenberg.example.com/forms/chromium/convert/html`
   - Authentication: Basic Auth (credentials from `.api_credentials`)
   - Body Content Type: `Form-Data`
   - Form Parameters:
     - Name: `files`
     - Value: binary HTML file

### Typical use cases in n8n:
- Automatic invoice generation after payment (Stripe webhook → HTML → PDF → email)
- Weekly reports (data from DB → HTML template → PDF)
- Archiving web pages as PDF
- Converting documents uploaded by clients

---

## API Options

### Page settings (Chromium)

```bash
curl -u user:password \
  -X POST https://your-domain.com/forms/chromium/convert/html \
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
curl -u user:password \
  -X POST https://your-domain.com/forms/chromium/convert/url \
  -F 'url=https://spa-app.com' \
  -F 'waitDelay=3s' \
  -o result.pdf
```

---

## Supported Conversions

- HTML to PDF (via Chromium)
- Markdown to PDF
- DOCX, XLSX, PPTX, ODT to PDF (via LibreOffice)
- Merging multiple PDFs into one
- URL to PDF (page screenshot)

---

## Backup

Gotenberg is stateless — no persistent data. Nothing to back up.

---

## Documentation

- [Gotenberg Docs](https://gotenberg.dev/docs/getting-started)
- [API Routes](https://gotenberg.dev/docs/routes)
- [Chromium options](https://gotenberg.dev/docs/routes#chromium)
- [LibreOffice options](https://gotenberg.dev/docs/routes#libreoffice)
