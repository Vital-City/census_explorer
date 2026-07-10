# Methodology

The NYC census explorer lets you pick a spatial level and a variable, view it on a map and download the values for that level as a CSV. This note explains where every number comes from and how it is derived.

## Data sources

American Community Survey 5-year estimates, U.S. Census Bureau, accessed via the Census API. Confirm the release year in `metadata.json`. ACS 5-year is used because it is the only ACS product published at tract and block group level.

2020 Census PL 94-171 Redistricting Data, U.S. Census Bureau. Used for block level, which the ACS does not cover. It provides total population and race and ethnicity only.

Boundary files, NYC Department of City Planning, shoreline-clipped versions. Used for display so shading does not bleed into rivers and harbor. Census GEOIDs are preserved so the data join is exact.

Tract to NTA equivalency, NYC Department of City Planning. Used to aggregate tract estimates to neighborhood tabulation areas.

## Geographies

Block, block group, tract, NTA, PUMA and borough. PUMA is the closest census approximation to a community district. NTA values are built by aggregating the tracts that make up each NTA.

Not every variable exists at every level. ACS detailed tables stop at block group. The block level carries only what the 2020 decennial publishes, which is total population, race and ethnicity, and population density. Variables that do not exist at a given level are disabled in the menu rather than estimated.

Police precincts are not a census geography and are not included yet. A later phase will estimate precinct values by areal interpolation over the tracts that overlap each precinct.

## Calculations

Shares are computed against each variable's own ACS universe, not against total population. Poverty is a share of the population for whom poverty status is determined. Educational attainment is a share of the population age 25 and older. Unemployment is a share of the civilian labor force. Renter share and rent burden are shares of housing units. Each variable's universe is stated in the CSV and on the map.

Medians and dollar values, including median household income, median gross rent, median home value and median age, are single values and carry no share. Medians are not aggregated to NTA because a median of medians is not a valid statistic.

Population density is population divided by land area in square miles, using the land area of the shoreline-clipped boundary.

Rent burden uses renter households paying 30 percent or more of income, divided by renter households paying rent, with the not-computed cell removed from the denominator.

## Margins of error

Every ACS value ships with its margin of error. Shares use the standard Census derived-proportion formula. Aggregated counts at NTA use the Census aggregation formula. Margins of error grow at small geographies. At block group level they can be large enough that a single estimate should be read as a range, not a point. Decennial block counts carry no margin of error but are subject to the 2020 disclosure-avoidance noise, which is most visible at the block level.

## Reproducibility

The full pipeline is one R script, `build_census_explorer.R`, driven by an editable variable dictionary, `variables.csv`. To refresh the data, confirm the ACS release year, point the boundary paths at the current DCP files and re-run the script. Every variable code is validated against the official Census variable list at the start of each run, so a mistyped code stops the build instead of producing a wrong number.

## Limitations

ACS estimates are survey based and carry sampling error. Block group estimates are the noisiest and should be treated with care. Boundaries follow 2020 census vintage. NTA and PUMA do not align exactly with administrative neighborhoods or community districts. Block level is limited to the small decennial variable set by design.
