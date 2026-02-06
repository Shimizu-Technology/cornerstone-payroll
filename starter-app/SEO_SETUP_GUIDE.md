# SEO Setup Guide

A comprehensive checklist for setting up SEO on client web applications.

---

## Table of Contents
1. [Meta Tags](#1-meta-tags)
2. [Open Graph & Twitter Cards](#2-open-graph--twitter-cards)
3. [Robots.txt](#3-robotstxt)
4. [Sitemap.xml](#4-sitemapxml)
5. [Structured Data (JSON-LD)](#5-structured-data-json-ld)
6. [Google Search Console](#6-google-search-console)
7. [Google Business Profile](#7-google-business-profile-local-businesses)

---

## 1. Meta Tags

Add these to the `<head>` section of your `index.html`:

```html
<!-- Primary Meta Tags -->
<title>Business Name | Tagline or Location</title>
<meta name="title" content="Business Name | Tagline or Location" />
<meta name="description" content="150-160 character description of the business and services." />
<meta name="keywords" content="keyword1, keyword2, keyword3, location" />
<meta name="author" content="Business Name" />

<!-- Canonical URL (prevents duplicate content issues) -->
<link rel="canonical" href="https://example.com/" />

<!-- Theme Color (browser UI color on mobile) -->
<meta name="theme-color" content="#2d2a26" />
```

### Best Practices:
- **Title**: 50-60 characters, include business name and primary keyword
- **Description**: 150-160 characters, compelling and includes call-to-action
- **Keywords**: 5-10 relevant keywords (less important for Google, still used by some engines)

---

## 2. Open Graph & Twitter Cards

These control how your site appears when shared on social media.

```html
<!-- Open Graph / Facebook -->
<meta property="og:type" content="website" />
<meta property="og:url" content="https://example.com/" />
<meta property="og:title" content="Business Name | Tagline" />
<meta property="og:description" content="Short description for social sharing." />
<meta property="og:image" content="https://example.com/og-image.jpg" />

<!-- Twitter -->
<meta property="twitter:card" content="summary_large_image" />
<meta property="twitter:url" content="https://example.com/" />
<meta property="twitter:title" content="Business Name | Tagline" />
<meta property="twitter:description" content="Short description for social sharing." />
<meta property="twitter:image" content="https://example.com/og-image.jpg" />
```

### Image Requirements:
- **Recommended size**: 1200x630 pixels
- **Minimum size**: 600x315 pixels
- **Format**: JPG or PNG
- **File size**: Under 1MB

### Testing Tools:
- [Facebook Sharing Debugger](https://developers.facebook.com/tools/debug/)
- [Twitter Card Validator](https://cards-dev.twitter.com/validator)

---

## 3. Robots.txt

Create `public/robots.txt` to control search engine crawling.

```txt
# Website Name
# https://example.com

User-agent: *
Allow: /

# Sitemap location
Sitemap: https://example.com/sitemap.xml

# Disallow private/admin areas
Disallow: /admin
Disallow: /admin/*
Disallow: /api/
Disallow: /dashboard

# Allow public pages explicitly (optional but helpful)
Allow: /
Allow: /about
Allow: /services
Allow: /contact
```

### Common Disallow Patterns:
- `/admin` - Admin dashboards
- `/api/` - API endpoints
- `/login`, `/signup` - Auth pages
- `/cart`, `/checkout` - E-commerce flows (sometimes)
- `/*?*` - URLs with query parameters (optional)

---

## 4. Sitemap.xml

Create `public/sitemap.xml` listing all public pages.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://example.com/</loc>
    <lastmod>2026-01-21</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>https://example.com/about</loc>
    <lastmod>2026-01-21</lastmod>
    <changefreq>monthly</changefreq>
    <priority>0.8</priority>
  </url>
  <url>
    <loc>https://example.com/services</loc>
    <lastmod>2026-01-21</lastmod>
    <changefreq>monthly</changefreq>
    <priority>0.9</priority>
  </url>
  <url>
    <loc>https://example.com/contact</loc>
    <lastmod>2026-01-21</lastmod>
    <changefreq>monthly</changefreq>
    <priority>0.8</priority>
  </url>
</urlset>
```

### Priority Guidelines:
- `1.0` - Homepage
- `0.9` - Core service/product pages
- `0.8` - About, Contact, secondary pages
- `0.5-0.7` - Blog posts, less important pages

### Netlify SPA Configuration:
Update `public/_redirects` to serve SEO files directly:

```
# SEO files - serve directly
/robots.txt    /robots.txt    200
/sitemap.xml   /sitemap.xml   200

# SPA fallback
/*    /index.html   200
```

---

## 5. Structured Data (JSON-LD)

Add structured data to help search engines understand your content. This enables rich results (star ratings, business info, etc.).

### Local Business Schema

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "LocalBusiness",
  "name": "Business Name",
  "description": "Business description here.",
  "url": "https://example.com",
  "logo": "https://example.com/logo.png",
  "image": "https://example.com/logo.png",
  "telephone": "+1-555-555-5555",
  "email": "contact@example.com",
  "address": {
    "@type": "PostalAddress",
    "streetAddress": "123 Main Street, Suite 100",
    "addressLocality": "City",
    "addressRegion": "ST",
    "postalCode": "12345",
    "addressCountry": "US"
  },
  "geo": {
    "@type": "GeoCoordinates",
    "latitude": 40.7128,
    "longitude": -74.0060
  },
  "openingHoursSpecification": [
    {
      "@type": "OpeningHoursSpecification",
      "dayOfWeek": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"],
      "opens": "09:00",
      "closes": "17:00"
    }
  ],
  "priceRange": "$$",
  "areaServed": {
    "@type": "Place",
    "name": "City, State"
  },
  "sameAs": [
    "https://facebook.com/businessname",
    "https://instagram.com/businessname",
    "https://linkedin.com/company/businessname"
  ]
}
</script>
```

### Common Schema Types:
| Business Type | @type Value |
|--------------|-------------|
| General | `LocalBusiness` |
| Restaurant | `Restaurant` |
| Medical | `MedicalBusiness` |
| Legal | `LegalService` |
| Accounting | `AccountingService` |
| Real Estate | `RealEstateAgent` |
| Auto | `AutoRepair` or `AutoDealer` |

### Website Schema (Add for all sites)

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "WebSite",
  "name": "Business Name",
  "url": "https://example.com"
}
</script>
```

### Testing Tools:
- [Google Rich Results Test](https://search.google.com/test/rich-results)
- [Schema.org Validator](https://validator.schema.org/)

---

## 6. Google Search Console

### Setup Steps:

1. **Go to** [Google Search Console](https://search.google.com/search-console)

2. **Add Property**
   - Click "Add Property"
   - Choose "Domain" or "URL prefix"
   - Enter the domain

3. **Verify Ownership** (choose one method):

   **Option A: DNS TXT Record** (recommended for domain-level)
   - Google provides a TXT record value
   - Add to DNS settings (Netlify, Cloudflare, etc.)
   - Format: `google-site-verification=XXXXX`
   - Wait 5-15 minutes for propagation
   
   **Option B: HTML Meta Tag** (faster)
   - Google provides a meta tag
   - Add to `<head>` in index.html
   - Deploy and verify immediately

4. **Submit Sitemap**
   - Go to Sitemaps in left sidebar
   - Enter full URL: `https://example.com/sitemap.xml`
   - Click Submit

5. **Request Indexing** (optional but speeds things up)
   - Go to URL Inspection
   - Enter each public URL
   - Click "Request Indexing"

### What to Monitor:
- **Coverage**: Which pages are indexed
- **Performance**: Search queries, clicks, impressions
- **Core Web Vitals**: Page speed metrics
- **Mobile Usability**: Mobile-friendly issues

---

## 7. Google Business Profile (Local Businesses)

For businesses with a physical location, set up a Google Business Profile for Maps visibility.

1. **Go to** [Google Business Profile](https://business.google.com)
2. **Add your business** with accurate info
3. **Verify** via postcard, phone, or email
4. **Add details**:
   - Business hours
   - Photos
   - Services/products
   - Description
5. **Keep updated** - respond to reviews, post updates

---

## Quick Checklist

```
□ Meta tags (title, description, keywords)
□ Open Graph tags for social sharing
□ Twitter Card tags
□ Canonical URL
□ Favicon and apple-touch-icon
□ robots.txt created
□ sitemap.xml created
□ Structured data (JSON-LD) added
□ Google Search Console verified
□ Sitemap submitted to Google
□ Google Business Profile (if local business)
```

---

## Template: Minimal index.html Head

```html
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  
  <!-- SEO -->
  <title>BUSINESS_NAME | TAGLINE</title>
  <meta name="description" content="DESCRIPTION" />
  <link rel="canonical" href="https://DOMAIN/" />
  
  <!-- Favicon -->
  <link rel="icon" type="image/png" href="/favicon.png" />
  <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
  
  <!-- Theme -->
  <meta name="theme-color" content="#HEXCOLOR" />
  
  <!-- Open Graph -->
  <meta property="og:type" content="website" />
  <meta property="og:url" content="https://DOMAIN/" />
  <meta property="og:title" content="BUSINESS_NAME | TAGLINE" />
  <meta property="og:description" content="DESCRIPTION" />
  <meta property="og:image" content="https://DOMAIN/og-image.jpg" />
  
  <!-- Twitter -->
  <meta property="twitter:card" content="summary_large_image" />
  <meta property="twitter:url" content="https://DOMAIN/" />
  <meta property="twitter:title" content="BUSINESS_NAME | TAGLINE" />
  <meta property="twitter:description" content="DESCRIPTION" />
  <meta property="twitter:image" content="https://DOMAIN/og-image.jpg" />
  
  <!-- Structured Data -->
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "LocalBusiness",
    "name": "BUSINESS_NAME",
    "url": "https://DOMAIN",
    "telephone": "PHONE",
    "address": {
      "@type": "PostalAddress",
      "streetAddress": "ADDRESS",
      "addressLocality": "CITY",
      "addressRegion": "STATE",
      "postalCode": "ZIP",
      "addressCountry": "US"
    }
  }
  </script>
</head>
```

---

*Last updated: January 2026*
