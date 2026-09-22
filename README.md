# FCPX Music Miner

Native macOS app voor het analyseren van muziekgebruik in Final Cut Pro libraries.

## Doel

- Meerdere `.fcpbundle` libraries in één batch scannen.
- Projecten **op projectniveau** tonen, dus niet alleen op Library-niveau.
- Oude versies/snapshots na de scan kunnen uitvinken.
- Muziek tellen op basis van de geselecteerde projecten.
- Gevonden tracks kopiëren naar **`FCPXMusicMiner` op de root van dezelfde schijf als de bron-`.fcpbundle`**.
- De Final Cut libraries zelf worden nooit gewijzigd.

Voorbeeld:

```
/Volumes/Weddings SSD/
├── Bruiloften 2025.fcpbundle
└── FCPXMusicMiner/
    ├── 00 - Meest gebruikt/
    └── 04 - Positie onbekend/
```

Als libraries op verschillende schijven staan, maakt de app per schijf een eigen `FCPXMusicMiner` map.

## Belangrijk over .fcpbundle

Final Cut bewaart ieder project in een eigen `CurrentVersion.fcpevent` SQLite-database in de library. Het schema daarvan is niet publiek gedocumenteerd. De app leest libraries daarom **read-only** en gebruikt een veilige best-effort scan om muziekbestanden aan projecten te koppelen.

Direct uit een `.fcpbundle` is de exacte timelinevolgorde nog niet betrouwbaar genoeg om opener/midden/einde te bepalen. Die classificatie wordt pas toegevoegd wanneer we de projectdatabase betrouwbaar kunnen ontleden; de app verzint die volgorde niet.

## Bouwen

```bash
./scripts/build-app.sh
```

Daarna staat de app in:

```
dist/FCPX Music Miner.app
```

GitHub Actions bouwt bij iedere push automatisch ook een zip van de app.

## Veiligheid

- Alleen lezen uit `.fcpbundle`.
- Nooit databases aanpassen.
- Alleen kopieën maken buiten de Library.
