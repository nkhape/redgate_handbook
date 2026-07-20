# Redgate Handbook

A no-nonsense overview of all of Redgate's solution areas, for the sales and solutions teams. Available in English and German.

- Flyway
- Monitor
- Toolbelt Essentials (TBE)

Plain static HTML — no backend. Hosted on GitHub Pages: https://nkhape.github.io/redgate_handbook/

See [CLAUDE.md](CLAUDE.md) for how it's built, translated, and deployed.

## Quick start

```
ruby generate.rb                     # build public/ (en + de) from templates + data
ruby -run -e httpd public -p 3000    # serve it locally at /redgate_handbook/ (see CLAUDE.md)
```
