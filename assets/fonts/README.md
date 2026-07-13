# Certificate Fonts

The pathway-completion certificate ([js/certificate-template.js](../../js/certificate-template.js)) uses three self-hosted fonts:

| Certificate element | Font | File |
|---|---|---|
| Recipient name | Shelley Script LT Std Regular | `ShelleyScriptLTStd.woff2` |
| Course lines | Sitka Heading Bold | `SitkaHeadingBold.woff2` |
| Date | Sitka Small Regular | `SitkaSmall.woff2` |

Provenance (July 2026): `ShelleyScriptLTStd.woff2` converted from the licensed OTF supplied by Key Wellness; `SitkaHeadingBold.woff2` extracted from the Sitka bold TTC (face index 3); `SitkaSmall.woff2` instanced from the Sitka variable font at `opsz=6, wght=400` (the "Small" named instance). All conversions done with fontTools.

If a file is ever missing, the renderer logs a console warning and falls back to Google Fonts (Pinyon Script for the name, EB Garamond for course/date). Replacement files may also be supplied as `.woff`, `.otf`, or `.ttf` with the same basenames — the renderer tries `.woff2` first.
