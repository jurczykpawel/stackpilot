# Cookie Hub (Klaro!) - Consent Management

A central GDPR/Cookie consent management server. Stop configuring cookie banners on every site separately.

## Installation

```bash
./local/deploy.sh cookie-hub
```

During installation you will be asked for a domain (e.g. `assets.your-domain.com`) where the scripts will be served.

## The "Centralization" Idea (Lazy Engineer Style)
Instead of configuring cookie plugins on every site (WordPress, GateFlow, landing pages) separately:
1. Set up **one** Cookie Hub.
2. Define services (Google Analytics, FB Pixel, Umami) in **one file** on the server.
3. Paste the same HTML snippet on all your sites.

When laws change or you add a new tracking tool, update only the file on the server and the changes appear everywhere instantly.

## When NOT to Use Cookie Hub? (Important!)

Klaro! is a great open-source tool, but it has its limits. Be aware of them:

1.  **Google AdSense / Programmatic Ads:**
    Klaro **IS NOT** a certified IAB TCF v2.2 partner. If your business model relies on **displaying ads** on your site (earning from AdSense on a blog), Google requires a certified CMP (e.g. Cookiebot, Quantcast). Otherwise ads may be blocked.
    *   **Verdict:** Earning from AdSense? Buy a paid CMP.
    *   **Verdict:** Selling your own products (GateFlow, e-books)? Cookie Hub is perfect.

2.  **Google Consent Mode v2 (Advanced):**
    In our configuration, Klaro works in "hard" mode - it completely blocks Google Ads/GA4 scripts until consent. It does not send "pings" to Google in anonymous mode (Basic Consent Mode). If you need advanced conversion modeling in Google Ads without consent, you must manually configure `gtag('consent', ...)` calls in the `config.js` file (requires JS knowledge).

## PRO: Consent Logging (GDPR Log)

The free version of Klaro saves consent only in the user's browser. If you want "proof" in a database (for peace of mind during audits), you can send consent info to your **n8n**.

### 1. Code for `config.js`
Edit the config file and add a `callback` function.

```javascript
var klaroConfig = {
    // ... rest of configuration ...

    // Function triggered on consent change
    callback: function(consent, app) {
        var payload = {
            timestamp: new Date().toISOString(),
            consents: consent, // Object e.g. { googleAnalytics: true, marketing: false }
            url: window.location.href
        };

        // Send to your n8n (Webhook)
        // Using navigator.sendBeacon to ensure delivery on page close
        var webhookUrl = "https://n8n.your-domain.com/webhook/cookie-consent-log";
        var blob = new Blob([JSON.stringify(payload)], {type : 'application/json'});
        navigator.sendBeacon(webhookUrl, blob);
    },

    // ... rest of configuration ...
};
```

### 2. Logic in n8n (Visualization)
Create a simple workflow:

```mermaid
graph LR
    A[Webhook Node<br/>(POST)] --> B[Set Node<br/>(Format Data)]
    B --> C[Postgres / NocoDB<br/>(Insert Row)]
```

**What to save in the database?**
- `timestamp` (When?)
- `consents` (What was consented to? JSON)
- `url` (On which page?)
- **Do not save IP** (unless you have a valid reason and GDPR allows it). An anonymous statistical log is legally safer.

## Integration (Step by Step)

### 1. Add scripts to your site
Paste the following code into the `<head>` section of every page:

```html
<!-- Klaro styles and config -->
<link rel="stylesheet" href="https://YOUR-COOKIE-DOMAIN/klaro.css" />
<script defer type="text/javascript" src="https://YOUR-COOKIE-DOMAIN/config.js"></script>
<!-- Main Klaro script -->
<script defer type="text/javascript" src="https://YOUR-COOKIE-DOMAIN/klaro.js"></script>
```

## Example Library (Copy-Paste)

For Klaro to work, you must change how tracking codes are pasted.
Rule: Change `type="text/javascript"` to `type="text/plain"` and add `data-name="serviceName"`.

### Google Tag Manager (GTM) - Simplest Method
If you use GTM, the easiest approach is to block loading the entire container until consent.
Requires defining a `googleTagManager` service in `config.js`.

```html
<!-- Google Tag Manager -->
<script type="text/plain" data-type="application/javascript" data-name="googleTagManager">
(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':
new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],
j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src=
'https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);
})(window,document,'script','dataLayer','GTM-XXXXXXX');
</script>
<!-- End Google Tag Manager -->
```

### Google Analytics 4 (GA4) - Direct
Requires defining a `googleAnalytics` service in `config.js`.

```html
<script async type="text/plain" data-type="application/javascript" data-name="googleAnalytics" src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXX"></script>
<script type="text/plain" data-type="application/javascript" data-name="googleAnalytics">
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXX');
</script>
```

### Meta Pixel (Facebook Ads)
Requires defining a `metaPixel` service in `config.js`.

```html
<script type="text/plain" data-type="application/javascript" data-name="metaPixel">
!function(f,b,e,v,n,t,s)
{if(f.fbq)return;n=f.fbq=function(){n.callMethod?
n.callMethod.apply(n,arguments):n.queue.push(arguments)};
if(!f._fbq)f._fbq=n;n.push=n;n.loaded=!0;n.version='2.0';
n.queue=[];t=b.createElement(e);t.async=!0;
t.src=v;s=b.getElementsByTagName(e)[0];
s.parentNode.insertBefore(t,s)}(window, document,'script',
'https://connect.facebook.net/en_US/fbevents.js');
fbq('init', 'YOUR_PIXEL_ID');
fbq('track', 'PageView');
</script>
```

### Umami (Your Own Analytics)
Requires a `umami` service in `config.js`.

```html
<script
  type="text/plain"
  data-type="application/javascript"
  data-name="umami"
  src="https://stats.your-domain.com/script.js"
  data-website-id="your-umami-id">
</script>
```

### Microsoft Clarity (Heatmaps)
Requires a `clarity` service in `config.js`.

```html
<script type="text/plain" data-type="application/javascript" data-name="clarity">
    (function(c,l,a,r,i,t,y){
        c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};
        t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;
        y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);
    })(window, document, "clarity", "script", "YOUR_PROJECT_ID");
</script>
```

### YouTube Embed (Blocking videos)
Replace `src` with `data-src` and add `data-name="youtube"`.

```html
<!-- Video blocked until consent -->
<iframe
  width="560" height="315"
  data-name="youtube"
  data-src="https://www.youtube.com/embed/VIDEO_ID"
  frameborder="0"
  allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
  allowfullscreen>
</iframe>
```

---

## Editing Configuration

The configuration is located on your server at:
`/var/www/cookie-hub/public/config.js`

To edit the file locally:
1. Download it: `./local/sync.sh down /var/www/cookie-hub/public/config.js ./config.js --ssh=ALIAS`
2. Edit in VS Code (add new services to the `services` array).
3. Upload back: `./local/sync.sh up ./config.js /var/www/cookie-hub/public/config.js --ssh=ALIAS`

## Polish Language

The system is fully configured in Polish. Buttons ("Accept all", "Reject"), purpose descriptions and messages are ready to use without any additional changes.
