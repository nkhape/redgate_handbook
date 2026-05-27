# Redgate Handbook — Project Context

## What this is
An internal product reference site for Redgate's sales and solutions teams. Built by Nick Hape (Solutions Engineer at Redgate Software). The goal is one fast, easy place for non-technical colleagues to find key info about each product.

## Stack
- Ruby on Rails 8.1 + Tailwind CSS 4
- Content managed via `config/locales/products.yml` (i18n)
- Single shared template: `app/views/pages/product.html.erb`
- Route: `/products/:product` → `PagesController#product`

## Running locally
From the WSL terminal in VS Code:
```
bin/dev
```
Then open http://localhost:3000

## Deployment
- Live at: https://redgate-handbook.onrender.com
- Auto-deploys from the `main` branch via Render
- Branch strategy: `dev` for work-in-progress, merge to `main` to go live

## Products
- Flyway
- Monitor
- Test Data Manager (`test_data_manager`)
- SQL Toolbelt Essentials (`toolbelt_essentials`)

## Product page structure (standard across all products)
1. Header — name + tagline
2. What it does — short description
3. Key Features — cards with title, description, screenshot placeholder
4. Supported Platforms — database logo icons (devicons CDN)
5. Who it's for — target audience
6. Useful Links — docs, demos, etc.
7. Why Redgate — sales closer

## Current status
- Monitor page has been fully updated to the new structure above
- Flyway, TDM, and Toolbelt Essentials still use the old flat bullet-point format and need updating
- Screenshot placeholders are in place — real screenshots to be added later

## Key files
- `config/locales/products.yml` — all product content
- `app/views/pages/product.html.erb` — shared product page template
- `app/views/pages/home.html.erb` — home page with product cards
- `app/views/layouts/application.html.erb` — navbar + layout
- `app/controllers/pages_controller.rb` — routing logic
- `bin/render-build.sh` — Render deployment build script
