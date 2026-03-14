# WBTenders

Android app for tracking West Bengal eProcurement tender statuses from [wbtenders.gov.in](https://wbtenders.gov.in).

## Features

### Watchlist (SMS-based)
- Reads your SMS inbox and automatically extracts tenders from NICSI/NIC notifications
- Shows Tender ID, Bid ID, and current status (Evaluated / Opened / Decrypted) for each message
- Tap any card to fetch the live tender status from the portal

### Advanced Search
- Search tenders by Tender ID, reference number, organisation, department, date range, value, and more
- Cascading dropdowns (Organisation → Department → Division → Sub-division → Branch)
- Paginated results with numbered page buttons and First/Last navigation
- Tap any result to open the full Tender Details page

### Tender Details
- Auto-solves the CAPTCHA (up to 10 retries) using Google ML Kit OCR with colour-filter preprocessing
- Falls back to manual CAPTCHA entry after 10 failed attempts
- Renders the portal's **Basic Details**, **Work Item Details**, **Critical Dates**, **Tender Fee Details**, **EMD Fee Details**, **Tender Inviting Authority**, **Payment Instruments**, **Covers Information**, and **Tenders Documents** sections
- Document links (NIT, BOQ, etc.) are tappable and open externally
- BOQ Comparative Chart parsed from the portal's `.xlsx` file and rendered with lowest-bidder highlighting

## Architecture

```
tender_app/lib/
  main.dart                      — app entry point, bottom tab bar (Watchlist / Search)
  models/
    sms_tender.dart              — SmsTender: parsed SMS fields
    tender_result.dart           — TenderResult: search result fields + links
    summary_section.dart         — SummarySection: rendered detail sections
  services/
    sms_service.dart             — reads SMS inbox, extracts tender/bid IDs and status
    captcha_service.dart         — ML Kit OCR with colour-filter + dilation preprocessing
    tender_service.dart          — session management, CAPTCHA flow, result + detail parsing
    advanced_search_service.dart — advanced search form, cascade dropdowns, pagination, detail parsing
  screens/
    home_screen.dart             — Watchlist tab: SMS tender list
    tender_detail_screen.dart    — tender status detail (auto + manual CAPTCHA, BOQ chart)
    advanced_search_screen.dart  — Search tab: form, results, paginator, detail viewer
```

## CAPTCHA Solving

The site CAPTCHA has **black characters** on a white background with coloured noise (blue dots, diagonal lines). The pipeline:

1. Flatten RGBA → white background
2. Colour-filter: keep only pixels where R, G, B all < 80 (black chars only)
3. Morphological dilation (3×3 kernel) to thicken thin/broken strokes
4. Add 10 px white padding on all sides
5. Scale up 4× with cubic interpolation
6. Google ML Kit Latin text recognition
7. Extract text elements sorted by horizontal position, filter by confidence ≥ 0.4

## Building

```bash
cd tender_app
flutter pub get
flutter build apk --release
```

Requires Android SDK with `minSdkVersion 21`.

## Dependencies

| Package | Purpose |
|---|---|
| `dio` + `dio_cookie_manager` | HTTP client with session cookie support |
| `html` | HTML parsing for page scraping |
| `google_mlkit_text_recognition` | On-device OCR for CAPTCHA solving |
| `image` | Image preprocessing (colour filter, dilation, scaling) |
| `flutter_sms_inbox` | Reading the device SMS inbox |
| `permission_handler` | SMS + storage runtime permissions |
| `url_launcher` | Opening document links externally |
| `excel` | Parsing BOQ Comparative Chart `.xlsx` files |
| `cookie_jar` | Persistent cookie storage |
