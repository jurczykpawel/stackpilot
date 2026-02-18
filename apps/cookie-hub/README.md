# 🍪 Cookie Hub (Klaro!) - Zarządzanie Zgodami

Centralny serwer zarządzania zgodami RODO/Cookies. Zapomnij o konfigurowaniu banerów na każdej stronie z osobna.

## 🚀 Instalacja

```bash
./local/deploy.sh cookie-hub
```

Podczas instalacji zostaniesz poproszony o podanie domeny (np. `assets.twojadomena.pl`), pod którą będą serwowane skrypty.

## 💡 Idea "Centralizacji" (Lazy Engineer Style)
Zamiast konfigurować wtyczki do cookies na każdej stronie (WordPress, GateFlow, Landing Page) z osobna:
1. Stawiasz **jeden** Cookie Hub.
2. Definujesz usługi (Google Analytics, Pixel FB, Umami) w **jednym pliku** na serwerze.
3. Wklejasz ten sam kod HTML na wszystkie swoje strony.

Gdy zmieni się prawo lub dodasz nowe narzędzie śledzące, aktualizujesz tylko plik na Mikrusie, a zmiany pojawiają się wszędzie natychmiastowo.

## ⚠️ Kiedy NIE używać Cookie Hub? (Ważne!)

Klaro! to świetne narzędzie Open Source, ale ma swoje granice. Bądź ich świadomy:

1.  **Google AdSense / Reklamy Programmatic:**
    Klaro **NIE JEST** certyfikowanym partnerem IAB TCF v2.2. Jeśli Twój model biznesowy opiera się na **wyświetlaniu reklam** na swojej stronie (zarabiasz na AdSense na blogu), Google wymaga certyfikowanego CMP (np. Cookiebot, Quantcast). W przeciwnym razie reklamy mogą zostać zablokowane.
    *   **Werdykt:** Zarabiasz na AdSense? ➡️ Kup płatne CMP.
    *   **Werdykt:** Sprzedajesz swoje produkty (GateFlow, E-booki)? ➡️ Cookie Hub jest idealny.

2.  **Google Consent Mode v2 (Zaawansowany):**
    W naszej konfiguracji Klaro działa w trybie "twardym" – całkowicie blokuje skrypty Google Ads/GA4 do momentu zgody. Nie wysyła "pingów" do Google w trybie anonimowym (Basic Consent Mode). Jeśli potrzebujesz zaawansowanego modelowania konwersji w Google Ads przy braku zgody, musisz ręcznie skonfigurować wywołania `gtag('consent', ...)` w pliku `config.js` (wymaga wiedzy JS).

## 🛡️ PRO: Rejestrowanie Zgód (RODO Log)

Wersja darmowa Klaro zapisuje zgodę tylko w przeglądarce użytkownika. Jeśli chcesz mieć "dowód" w bazie danych (dla świętego spokoju przy kontroli), możesz wysłać informację o zgodzie do swojego **n8n**.

### 1. Kod do `config.js`
Edytuj plik konfiguracyjny i dodaj funkcję `callback`.

```javascript
var klaroConfig = {
    // ... reszta konfiguracji ...
    
    // Funkcja uruchamiana po zmianie zgody
    callback: function(consent, app) {
        // Wysyłamy tylko jeśli to ostateczna decyzja (np. zamknięcie modala)
        // Możesz tu dodać logikę debounce, żeby nie wysyłać przy każdym kliknięciu
        
        var payload = {
            timestamp: new Date().toISOString(),
            consents: consent, // Obiekt np. { googleAnalytics: true, marketing: false }
            url: window.location.href
        };

        // Wyślij do Twojego n8n (Webhook)
        // Używamy navigator.sendBeacon dla pewności wysyłki przy zamykaniu strony
        var webhookUrl = "https://n8n.twojadomena.pl/webhook/cookie-consent-log";
        var blob = new Blob([JSON.stringify(payload)], {type : 'application/json'});
        navigator.sendBeacon(webhookUrl, blob);
    },
    
    // ... reszta konfiguracji ...
};
```

### 2. Logika w n8n (Wizualizacja)
Stwórz prosty workflow:

```mermaid
graph LR
    A[Webhook Node<br/>(POST)] --> B[Set Node<br/>(Formatowanie Danych)]
    B --> C[Postgres / NocoDB<br/>(Insert Row)]
```

**Co zapisywać w bazie?**
- `timestamp` (Kiedy?)
- `consents` (Na co się zgodził? JSON)
- `url` (Na jakiej stronie?)
- **Nie zapisuj IP** (chyba że masz ważny powód i RODO to dopuszcza). Anonimowy log statystyczny jest bezpieczniejszy prawnie.

## 🛠️ Integracja (Krok po kroku)

### 1. Dodaj skrypty do swojej strony
Wklej poniższy kod do sekcji `<head>` na każdej swojej stronie:

```html
<!-- Style i konfiguracja Klaro -->
<link rel="stylesheet" href="https://TWOJA-DOMENA-COOKIES/klaro.css" />
<script defer type="text/javascript" src="https://TWOJA-DOMENA-COOKIES/config.js"></script>
<!-- Główny skrypt Klaro -->
<script defer type="text/javascript" src="https://TWOJA-DOMENA-COOKIES/klaro.js"></script>
```

## 📋 Biblioteka Przykładów (Kopiuj-Wklej)

Aby Klaro działało, musisz zmienić sposób wklejania kodów śledzących.
Zasada: Zmieniasz `type="text/javascript"` na `type="text/plain"` i dodajesz `data-name="nazwaUslugi"`.

### Google Tag Manager (GTM) - Najprostsza metoda
Jeśli używasz GTM, najłatwiej jest zablokować wczytywanie całego kontenera do czasu zgody.
Wymaga zdefiniowania usługi `googleTagManager` w `config.js`.

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

### Google Analytics 4 (GA4) - Bezpośrednio
Wymaga zdefiniowania usługi `googleAnalytics` w `config.js`.

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
Wymaga zdefiniowania usługi `metaPixel` w `config.js`.

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
fbq('init', 'TWOJ_PIXEL_ID');
fbq('track', 'PageView');
</script>
```

### Umami (Twoja własna analityka)
Wymaga usługi `umami` w `config.js`.

```html
<script 
  type="text/plain" 
  data-type="application/javascript" 
  data-name="umami" 
  src="https://stats.twojadomena.pl/script.js" 
  data-website-id="twoje-id-umami">
</script>
```

### Microsoft Clarity (Heatmapy)
Wymaga usługi `clarity` w `config.js`.

```html
<script type="text/plain" data-type="application/javascript" data-name="clarity">
    (function(c,l,a,r,i,t,y){
        c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};
        t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;
        y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);
    })(window, document, "clarity", "script", "TWOJ_PROJEKT_ID");
</script>
```

### YouTube Embed (Blokowanie filmów)
Zastąp `src` przez `data-src` i dodaj `data-name="youtube"`.

```html
<!-- Film zablokowany do czasu zgody -->
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

## ⚙️ Edycja konfiguracji

Konfiguracja znajduje się na Twoim Mikrusie w pliku:
`/var/www/cookie-hub/public/config.js`

Aby edytować plik lokalnie:
1. Pobierz go: `./local/sync.sh down /var/www/cookie-hub/public/config.js ./config.js --ssh=mikrus`
2. Wyedytuj w VS Code (dodaj nowe usługi do tablicy `services`).
3. Wyślij z powrotem: `./local/sync.sh up ./config.js /var/www/cookie-hub/public/config.js --ssh=mikrus`

## 🇵🇱 Język Polski
System jest w pełni skonfigurowany w języku polskim. Przyciski ("Zaakceptuj wszystko", "Odrzuć"), opisy celów i komunikaty są gotowe do użycia bez żadnych dodatkowych zmian.