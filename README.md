# NYC census explorer

A map that lets you pick a spatial level and a variable for all of New York City, read
it as a choropleth and download the values for that level as a CSV. Built to make
pulling census variables at tract, block group and neighborhood level fast.

## Repo layout

    build_census_explorer.R   R pipeline: pulls data, computes shares + MOE, writes outputs
    variables.csv             editable variable dictionary (add or remove rows here)
    methodology.md            plain-language methodology (also served at docs/methodology.md)
    docs/                     GitHub Pages root (Settings > Pages > deploy from /docs)
      index.html              the explorer (standalone + ?embed=1 for Ghost later)
      data/                   pipeline output; currently SYNTHETIC demo data for UI testing

## Refresh the data (run locally)

1. Install a Census API key once: `tidycensus::census_api_key("KEY", install = TRUE)`, restart R.
2. Confirm `ACS_YEAR` in the script is the newest ACS 5-year release.
3. Point `BOUNDARY_DIR` at the folder holding the five DCP GeoJSON files (tracts, blocks,
   NTA, PUMA, borough). Block groups are dissolved from the blocks, and the tract-to-NTA
   crosswalk is read from the tract file, so neither is a separate download.
4. `source("build_census_explorer.R")`. It validates every variable code first and stops
   on any bad code. At the end it prints a cross-check (citywide population, area counts).
5. Paste the cross-check back so we confirm the pull before publishing.

## Preview the map

The map uses fetch(), so open it over http, not file://:

    cd docs && python -m http.server 8000    # then visit http://localhost:8000

## Deploy

Push to the vitalcity-nyc GitHub org, enable Pages from /docs.

Note: docs/data currently holds synthetic demo values so the UI is clickable. The pipeline
overwrites it with real data on first run.
