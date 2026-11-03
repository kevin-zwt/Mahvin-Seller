# Mahvin Seller - Flipkart Top Selling Finder

A Flutter app for Flipkart sellers. It shows category-wise top selling products
on Flipkart, lets the seller type any product to find its best selling matches,
finds wholesale sellers for a product on IndiaMART and TradeIndia, reads a
pasted product link into listing-ready data, and suggests selling growth
strategies. Product lists are sorted by popularity, display thumbnails, and
open the live Flipkart product page when tapped.

There is no catalog, order book, sample products, or add-product flow. The only
saved state is the optional Serper API key and the theme preference.

## What it does

- Lets the seller pick a Flipkart category such as Mobiles, Electronics,
  Fashion, Home & Kitchen, Appliances, Beauty, Toys, or Sports.
- Lets the seller type any product, such as "cotton kurti" or "steel water
  bottle", and loads Flipkart's most popular matches.
- Loads the category or product search page, sorted by popularity, through a
  public reader, so no API key is needed to start.
- Uses the Serper Webpage Scrape API first when a Serper key is saved.
- Extracts product names, images, prices, MRP, and discount labels from the page.
- Keeps the page's popularity order and shows up to 20 products.
- Displays product images with rank indicators and fallbacks for missing images.
- Lets sellers click the product name or "View on Flipkart" to open the live product page.
- Marks the first result as the best seller for that category or search.
- Shows the Flipkart page title and a short source summary in the app.
- Falls back to Flipkart product pages returned by Serper search if both page
  readers cannot be read.
- Caches each category or search in memory for the session, so switching back
  is instant.
- Lets the seller switch between **Top Selling**, **Product Sourcing**, **Growth Strategies**, and **Product Data** via bottom navigation.
- Reads a pasted product link from Flipkart, Amazon, Meesho, Myntra, or another public store.
- Extracts the product title, description, brand, price, MRP, discount, rating, review count, availability, seller, category, SKU, key features, keywords, photos, and specifications.
- Shows product photos in a grid with per-photo download, per-photo link copy, and download-all actions.
- Shows every listing field separately with its own copy button, plus a copy-all summary.
- Uploads a Meesho `.xlsx` listing template, fills its product-specific columns from the fetched product, and downloads the filled file for direct upload.
- Lets the seller edit matched fields and fill unmatched template columns before downloading the Excel.
- Copies a listing-ready summary to the clipboard and opens the original product page.
- Uses the public reader first and falls back to the saved Serper key when a store blocks the reader.
- Searches web articles and seller growth playbooks for topics like ad campaigns (PLA), listing SEO, pricing strategies, reducing returns (RTO), Flipkart Assured, and review management.
- Reuses the saved Serper API key to query live Google web search results on demand, with a rich curated playbook fallback.
- Provides direct links on strategy cards to read the full source guides in the browser.
- Lets the seller search wholesale suppliers for any product on **Product Sourcing**.
- Reads live IndiaMART and TradeIndia search pages through the public reader, so no API key is needed for sourcing.
- Shows seller name, product title, city, price, MOQ, and verification badges when the portal exposes them.
- Loads the public seller profile to show the contact person's name and phone number, with a clear fallback when a portal hides the phone.
- Opens the seller's live IndiaMART or TradeIndia page when tapped.
- Uses a Serper web search only as a fallback when both portal pages yield no sellers and a key is saved.

All results are fetched on demand and never stored.

## Getting started

```bash
flutter pub get
flutter run
flutter analyze
flutter test
```

The app starts loading products automatically. A Serper key is optional; add
one from the **Add Serper key** button if you want Serper to be tried first.

## How the data is loaded

For each category or typed product search, the app builds a Flipkart search URL
sorted by popularity:

```text
https://www.flipkart.com/search?q=cotton+kurti&sort=popularity
```

It first tries the public reader:

```text
https://r.jina.ai/https://www.flipkart.com/search?q=cotton+kurti&sort=popularity
```

If a Serper key is saved, the app first posts to `https://scrape.serper.dev`:

```json
{
  "url": "https://www.flipkart.com/search?q=cotton+kurti&sort=popularity",
  "includeMarkdown": true
}
```

The `q` value comes from the selected category or the typed search. The app
reads the returned markdown, finds product-page links, and collects the product
title plus the nearby price line. Duplicate cards for the same product are
removed.

If both readers return no readable product cards, the app makes one Serper
search request for `site:flipkart.com/p/ cotton kurti top selling` (using the
selected category or typed search) and uses the matching Flipkart product pages
as a fallback. The search fallback requires a Serper key.

Serper scrape and search requests use Serper credits. The public reader needs
no key but may be rate limited during heavy use.

## How product sourcing is loaded

The seller types a product on the **Product Sourcing** tab. The app reads the
public IndiaMART and TradeIndia search pages through `https://r.jina.ai/`:

```text
https://dir.indiamart.com/search.mp?ss=cotton+kurti
https://www.tradeindia.com/search.html?keyword=cotton+kurti
```

It extracts company names, seller URLs, product titles, locations, prices, MOQ,
and verification labels from the returned markdown. IndiaMART tracking query
parameters are stripped so the saved seller URL stays clean. Results from both
portals are merged, de-duplicated, and capped at 20.

After the listings appear, the app reads each seller's public profile in the
background (three at a time) to add contact details:

- **IndiaMART:** reads the company page as HTML to get the public virtual phone
  number and the contact person shown in the seller footer.
- **TradeIndia:** reads the seller profile for the owner/contact person and
  designation. TradeIndia hides seller phone numbers behind its own login or
  OTP flow, so the card shows `Phone number not published` in that case.
- Contact lookups are cached for the session and failures never block the
  seller list.

Portal pages are tried first because they need no key. If both return no
sellers and a Serper key is saved, the app runs a scoped web search
(`site:indiamart.com OR site:tradeindia.com`) as a fallback.

## How product links are loaded

On **Product Data**, the seller pastes a full product URL. The app reads the
page as HTML through the public reader:

```text
https://r.jina.ai/https://www.flipkart.com/product-link
```

It parses JSON-LD Product data, OpenGraph tags, product headings, feature
bullets, specification tables, image tags, and common store-specific markup.
The result is normalised into one product record with up to 20 photos, 8 key
features, 12 keywords, and 20 specifications.

Some stores return a denial or captcha page with HTTP 200. The app detects
those pages and shows a clear error instead of treating them as products. If a
Serper key is saved, it retries the product URL through
`https://scrape.serper.dev` and parses the returned markdown metadata, images,
bullets, tables, and price/rating lines.

Photo downloads use the browser's Blob download support. If a browser blocks
the download, the app opens the photo in a new tab instead.

## How Meesho Excel templates are filled

After a product is fetched, upload the `.xlsx` template downloaded from Meesho.
The app scans the workbook for the header row, skips reference sheets such as
validation/example tabs, and maps columns by their names (product name, price,
MRP, brand, specs such as Color, Image 1, Image 2, and so on).

- One product is written to the first data row after the header, skipping an
  example/sample row when present.
- Matched values can be edited before download; unmatched template columns are
  listed in an expandable section so required fields such as HSN or GST can be
  added.
- Numeric columns are written as numbers, while codes such as HSN stay text.
- Meesho Price uses the scraped price; MRP is set so the price is 60% off it, so the strike
  price stays valid, using the scraped MRP only when the price is unavailable.
- Image columns receive the extracted image URLs.
- Existing formulas are kept unless the seller edits that cell.
- Other worksheets, styles, merged cells, formulas, and template parts are
  written back unchanged. Only the data row and shared-string table change.

Download the filled file, then upload it directly to Meesho. If a required
Meesho field is not present on the source product, fill it in the app or in
Excel before uploading.

## Limits

- Flipkart can change its page layout or temporarily block scraping. When that
  happens, the app shows an error with a retry action or uses the search
  fallback.
- Product pages on major stores can block the public reader or return a captcha
  page. Add a Serper key to enable the fallback, or open the product link in a
  browser and try again later.
- IndiaMART and TradeIndia can change their search markup or block the public
  reader. A portal with no readable sellers is skipped; if both are empty, the
  app shows a clear error or uses the Serper fallback.
- Contact details come from public seller pages. TradeIndia does not publish
  seller phone numbers without an in-portal verification step, and any portal
  can hide or change contact fields. Cards then show the contact person only or
  `Phone number not published`.
- Sourcing results are live listings, not verified suppliers. Confirm GST,
  quality, and terms before placing an order.
- Prices and discounts are copied from the page at load time and can change
  immediately.
- The list reflects Flipkart's popularity sort, not verified sales data. The
  "Best seller" badge marks the first popularity result. Check demand,
  competition, and supplier costs before buying stock.
- An internet connection is required. A Serper key is optional.
- Product data is copied from the public page and can be incomplete when a
  store hides details behind JavaScript, a login, or a captcha.
- Meesho templates change by category. The app detects common headers, but
  category-specific required fields or dropdown values may still need manual
  edits before Meesho accepts the file.
- Only one product is filled per template download. Use a separate template
  upload for each listing.
- Product links open in the device's external browser or product app.

## Project structure

```text
lib/
  main.dart                  # SharedPreferences + web trend, sourcing, and strategy services
  app.dart                   # MaterialApp, splash, themed shell
  core/                      # app info, theme, responsive helpers
  data/
    models/flipkart_category.dart # categories + typed FlipkartQuery
    models/trend_suggestion.dart  # product suggestion model with images & urls
    models/sourcing_supplier.dart # sourcing platform, supplier, snapshot models
    models/growth_strategy.dart   # growth strategy model
    models/product_link_data.dart # product link record, photos, specs
    trend_service.dart       # public reader, Serper, parsing, errors
    sourcing_service.dart    # IndiaMART/TradeIndia reader, parsing, Serper fallback
    growth_strategy_service.dart # web search & curated growth strategy service
    product_link_service.dart   # HTML/markdown product parsing + Serper fallback
    meesho_template_service.dart # Meesho .xlsx header mapping + row filling
  common/                    # shared cards, buttons, layout helpers
  core/download/             # browser image/file download and non-web fallback
  core/files/                # browser .xlsx template picker
  pages/
    splash/
    shell/                   # app bar & bottom navigation shell
    trends/                  # search, category picker, top selling list
    sourcing/                # B2B product search and supplier cards
    strategies/              # selling growth strategies, search, pillars
    product_data/            # pasted product link analyzer
test/
  trend_service_test.dart    # reader/Serper parsing, fallback, errors
  sourcing_test.dart         # portal parsing, contacts, platform filter, sourcing UI
  product_link_test.dart     # product parsing, blocked pages, Serper fallback, UI
  meesho_template_test.dart  # header detection, real template, edit/clear, XML preservation
  widget_test.dart           # search, category cache, and error flows
  growth_strategy_test.dart  # web strategy search & UI navigation tests
```
