# Title: NYC Census Explorer data pipeline
# Author: Vital City (generated with Claude, reviewed by Paul)
# Date: 2026
# Data sources:
#   - U.S. Census Bureau, American Community Survey 5-year estimates (via tidycensus / Census API)
#   - U.S. Census Bureau, 2020 Census PL 94-171 Redistricting Data (block-level counts)
#   - NYC Department of City Planning, shoreline-clipped boundary files (tract, block group, NTA, PUMA, borough)
#   - NYC DCP tract-to-NTA equivalency crosswalk
# Description: Pulls a fixed set of variables at multiple NYC geographies, computes
#   correct-universe shares and margins of error, joins to shoreline-clipped display
#   geometry, and writes per-geography data + geometry + a variable dictionary for the map.
# Dependencies: R (>= 4.5), tidycensus, tigris, sf, dplyr, tidyr, readr, jsonlite, rmapshaper
#
# HOW TO RUN
#   1. Get a Census API key: https://api.census.gov/data/key_signup.html
#   2. Set it once:  tidycensus::census_api_key("YOUR_KEY", install = TRUE)  then restart R.
#   3. Confirm ACS_YEAR below is the latest released ACS 5-year (see notes in config).
#   4. Point the DCP_* paths at the downloaded shoreline-clipped boundary files.
#   5. source("build_census_explorer.R")
#
# FIRST-RUN NOTE (anti-fabrication)
#   Variable codes live in variables.csv, not in this script. On the first run the
#   pipeline validates EVERY code against the official ACS/decennial variable list and
#   STOPS with the offending code if any is wrong or missing. Do not skip this. It is the
#   guardrail that keeps a mistyped code from silently producing a fabricated number.

suppressPackageStartupMessages({
  library(tidycensus); library(tigris); library(sf)
  library(dplyr); library(tidyr); library(readr); library(stringr); library(jsonlite)
  library(rmapshaper); library(purrr)
})
options(tigris_use_cache = TRUE)

# ------------------------------------------------------------------ config ----
# Confirm this is the newest ACS 5-year release before running. As of early 2026 the
# 2020-2024 ACS 5-year (ACS_YEAR = 2024) is the expected latest. Check:
#   https://www.census.gov/programs-surveys/acs/news/data-releases.html
ACS_YEAR    <- 2024
ACS_SURVEY  <- "acs5"
DEC_YEAR    <- 2020
DEC_SUMFILE <- "pl"          # PL 94-171 has block-level pop, race/ethnicity
STATE_FIPS  <- "36"
NYC_COUNTIES <- c("005", "047", "061", "081", "085")  # Bronx, Kings, NY, Queens, Richmond
OUT_DIR     <- "docs/data"   # docs/ so GitHub Pages can serve it directly
SIMPLIFY_KEEP <- 0.08        # geometry simplification (share of vertices kept); tune per level

# Shoreline-clipped DCP boundary files (downloaded from NYC Open Data as GeoJSON).
# Using DCP clipped boundaries, not raw TIGER, so choropleths do not bleed into water.
BOUNDARY_DIR <- "C:/Users/paulr/Dropbox/Vital City/Census Explorer/boundaries"
DCP_TRACT   <- file.path(BOUNDARY_DIR, "2020_Census_Tracts_20260710.geojson")
DCP_BLOCK   <- file.path(BOUNDARY_DIR, "2020_Census_Blocks_20260710.geojson")
DCP_NTA     <- file.path(BOUNDARY_DIR, "2020_Neighborhood_Tabulation_Areas_(NTAs)_20260710.geojson")
DCP_PUMA    <- file.path(BOUNDARY_DIR, "2020_Public_Use_Microdata_Areas_(PUMAs)_20260710.geojson")
DCP_BOROUGH <- file.path(BOUNDARY_DIR, "Borough_Boundaries_20260710.geojson")
# Block group has no DCP file. It is dissolved from the blocks on the 12-char GEOID.
# NTA crosswalk is not a separate file. It is built from the tract file's nta2020 column.

# borocode (1-5) to county GEOID (state 36 + county FIPS)
BORO_TO_GEOID <- c("1" = "36061", "2" = "36005", "3" = "36047", "4" = "36081", "5" = "36085")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# --------------------------------------------- load a boundary as clean GEOID ----
# Returns an sf with exactly one attribute column, GEOID, matching the census id
# that tidycensus/get_decennial return for that level, plus geometry in EPSG:4326.
load_boundary <- function(geo) {
  message("  loading boundary for ", geo, " ...")
  if (geo == "blockgroup") {
    blk <- st_read(DCP_BLOCK, quiet = TRUE) |> st_transform(4326)
    blk$GEOID <- substr(as.character(blk$geoid), 1, 12)   # block group = first 12 chars
    g <- rmapshaper::ms_dissolve(blk[, "GEOID"], field = "GEOID")
    return(g)
  }
  g <- st_read(switch(geo, tract = DCP_TRACT, block = DCP_BLOCK, nta = DCP_NTA,
                      puma = DCP_PUMA, borough = DCP_BOROUGH), quiet = TRUE) |>
    st_transform(4326)
  g$GEOID <- switch(geo,
    tract   = as.character(g$geoid),
    block   = as.character(g$geoid),
    nta     = as.character(g$nta2020),
    puma    = paste0("36", sprintf("%05d", as.integer(g$puma))),
    borough = unname(BORO_TO_GEOID[as.character(g$borocode)]))
  g[, "GEOID"]
}

# tract-to-NTA crosswalk, built straight from the tract file
build_nta_crosswalk <- function() {
  t <- st_read(DCP_TRACT, quiet = TRUE) |> st_drop_geometry()
  tibble(GEOID = as.character(t$geoid), nta_code = as.character(t$nta2020),
         nta_name = as.character(t$ntaname))
}

# ----------------------------------------------------------- read var config ----
vars <- read_csv("variables.csv", show_col_types = FALSE) |>
  filter(!is.na(id), id != "") |>
  mutate(across(everything(), ~ ifelse(is.na(.), "", .)))

split_codes <- function(x) if (x == "") character(0) else str_split(x, ";")[[1]] |> str_trim()

# exact token membership so "block" does not match "blockgroup"
has_geo <- function(geos_vec, g)
  vapply(geos_vec, function(s) g %in% str_split(s, fixed("|"))[[1]], logical(1))

# ------------------------------------------------------- validate all codes ----
validate_codes <- function() {
  message("Validating ACS variable codes against the official ", ACS_YEAR, " ", ACS_SURVEY, " list ...")
  acs_lu <- load_variables(ACS_YEAR, ACS_SURVEY, cache = TRUE)$name
  dec_lu <- load_variables(DEC_YEAR, DEC_SUMFILE, cache = TRUE)$name

  acs_needed <- vars |>
    filter(type %in% c("rate", "amount")) |>
    reframe(code = c(split_codes(paste(acs_est, collapse = ";")),
                     split_codes(paste(acs_universe, collapse = ";")),
                     split_codes(paste(universe_minus, collapse = ";")))) |>
    pull(code) |> unique()
  acs_needed <- acs_needed[acs_needed != ""]
  dec_needed <- vars |>
    reframe(code = c(split_codes(paste(dec_est, collapse = ";")),
                     split_codes(paste(dec_universe, collapse = ";")))) |>
    pull(code) |> unique()
  dec_needed <- dec_needed[dec_needed != ""]

  bad_acs <- setdiff(acs_needed, acs_lu)
  bad_dec <- setdiff(dec_needed, dec_lu)
  if (length(bad_acs)) stop("ACS codes not found in ", ACS_YEAR, " ", ACS_SURVEY, ": ",
                            paste(bad_acs, collapse = ", "), call. = FALSE)
  if (length(bad_dec)) stop("Decennial codes not found in ", DEC_YEAR, " ", DEC_SUMFILE, ": ",
                            paste(bad_dec, collapse = ", "), call. = FALSE)
  message("All variable codes validated.")
}

# ------------------------------------------------- ACS pull for a geography ----
# Returns a long table: GEOID, variable id, estimate, moe, universe, share, share_moe
pull_acs_level <- function(geo) {
  active <- vars |> filter(has_geo(geos, geo),
                           acs_est != "" | id == "pop_density")
  code_vars <- active |> filter(type %in% c("rate", "amount"), acs_est != "")
  all_codes <- code_vars |>
    reframe(c = c(split_codes(paste(acs_est, collapse=";")),
                  split_codes(paste(acs_universe, collapse=";")),
                  split_codes(paste(universe_minus, collapse=";")))) |>
    pull(c) |> unique()
  all_codes <- all_codes[all_codes != ""]

  geography <- switch(geo,
    blockgroup = "block group", tract = "tract",
    puma = "public use microdata area", borough = "county")
  message("  pulling ", nrow(code_vars), " ACS variables for ", geo, " ...")

  raw <- get_acs(geography = geography, variables = all_codes,
                 state = STATE_FIPS, county = if (geo == "puma") NULL else NYC_COUNTIES,
                 year = ACS_YEAR, survey = ACS_SURVEY, output = "wide", geometry = FALSE)
  if (geo == "puma") raw <- raw |> filter(str_detect(NAME, "NYC"))  # keep NYC PUMAs only

  est <- function(df, code) df[[paste0(code, "E")]]
  moe <- function(df, code) df[[paste0(code, "M")]]
  sum_est <- function(df, codes) rowSums(sapply(codes, function(c) est(df, c)), na.rm = TRUE)
  sum_moe <- function(df, codes) apply(sapply(codes, function(c) moe(df, c)), 1,
                                       function(m) moe_sum(m, na.rm = TRUE))

  out <- purrr::map_dfr(seq_len(nrow(code_vars)), function(i) {
    v <- code_vars[i, ]
    ecodes <- split_codes(v$acs_est)
    if (v$type == "amount") {
      tibble(GEOID = raw$GEOID, variable = v$id,
             estimate = est(raw, ecodes[1]), moe = moe(raw, ecodes[1]),
             universe = NA_real_, share = NA_real_, share_moe = NA_real_)
    } else {  # rate: numerator / (universe - universe_minus)
      num  <- sum_est(raw, ecodes); num_m <- sum_moe(raw, ecodes)
      den  <- est(raw, v$acs_universe)
      den_m <- moe(raw, v$acs_universe)
      if (v$universe_minus != "") {
        den   <- den - est(raw, v$universe_minus)
        den_m <- moe_sum(cbind(den_m, moe(raw, v$universe_minus)))  # conservative
      }
      share <- ifelse(den > 0, 100 * num / den, NA_real_)
      share_m <- 100 * moe_prop(num, den, num_m, den_m)
      tibble(GEOID = raw$GEOID, variable = v$id,
             estimate = num, moe = num_m, universe = den,
             share = share, share_moe = share_m)
    }
  })
  out
}

# ----------------------------------------- decennial pull for block level ----
pull_dec_block <- function() {
  active <- vars |> filter(has_geo(geos, "block"), dec_est != "" | id == "total_pop" | id == "pop_density")
  code_vars <- active |> filter(dec_est != "" | id == "total_pop")
  codes <- code_vars |>
    reframe(c = c(split_codes(paste(dec_est, collapse=";")),
                  split_codes(paste(dec_universe, collapse=";")))) |>
    pull(c) |> unique()
  codes <- unique(c(codes[codes != ""], "P1_001N"))
  message("  pulling ", length(codes), " decennial codes for block ...")

  raw <- get_decennial(geography = "block", variables = codes, state = STATE_FIPS,
                       county = NYC_COUNTIES, year = DEC_YEAR, sumfile = DEC_SUMFILE,
                       output = "wide", geometry = FALSE)

  purrr::map_dfr(seq_len(nrow(code_vars)), function(i) {
    v <- code_vars[i, ]
    if (v$id == "total_pop") {
      tibble(GEOID = raw$GEOID, variable = "total_pop",
             estimate = raw$P1_001N, moe = NA_real_, universe = NA_real_,
             share = NA_real_, share_moe = NA_real_)
    } else {
      ec <- split_codes(v$dec_est)
      num <- rowSums(as.matrix(raw[, ec, drop = FALSE]), na.rm = TRUE)
      den <- raw[[v$dec_universe]]
      tibble(GEOID = raw$GEOID, variable = v$id,
             estimate = num, moe = NA_real_, universe = den,
             share = ifelse(den > 0, 100 * num / den, NA_real_), share_moe = NA_real_)
    }
  })
}

# --------------------------------------------- NTA aggregation from tracts ----
# Counts aggregate by summing tracts (moe_sum). Shares recomputed from aggregated
# numerator and denominator (moe_prop). Medians are NOT aggregated and are excluded
# from NTA in variables.csv, because a median of medians is not a valid statistic.
aggregate_to_nta <- function(tract_long, crosswalk) {
  cw <- crosswalk |> mutate(GEOID = as.character(GEOID))
  df <- tract_long |> inner_join(cw, by = "GEOID")

  df |> group_by(nta_code, variable) |>
    summarise(
      estimate  = sum(estimate, na.rm = TRUE),
      moe       = moe_sum(moe, estimate, na.rm = TRUE),
      universe  = sum(universe, na.rm = TRUE),
      .groups = "drop") |>
    mutate(
      share     = ifelse(!is.na(universe) & universe > 0, 100 * estimate / universe, NA_real_),
      share_moe = ifelse(!is.na(universe) & universe > 0,
                         100 * moe_prop(estimate, universe, moe, moe_sum(moe)), NA_real_)) |>
    rename(GEOID = nta_code)
}

# --------------------------------------------------- geometry + density -------
attach_geometry_and_write <- function(long, geo, g) {
  message("  writing outputs for ", geo, " ...")
  g$GEOID <- as.character(g$GEOID)

  # population density: persons per square mile of land area (ALAND from geometry)
  areas_sqmi <- as.numeric(st_area(st_transform(g, 2263))) / 27878400  # ft^2 -> sq mi
  dens <- tibble(GEOID = g$GEOID, variable = "pop_density", area_sqmi = areas_sqmi)
  pop <- long |> filter(variable == "total_pop") |> select(GEOID, pop = estimate)
  dens <- dens |> left_join(pop, by = "GEOID") |>
    transmute(GEOID, variable,
              estimate = ifelse(area_sqmi > 0, pop / area_sqmi, NA_real_),
              moe = NA_real_, universe = NA_real_, share = NA_real_, share_moe = NA_real_)
  long <- bind_rows(long, dens)

  # wide data table, one row per GEOID, columns per variable
  wide <- long |>
    pivot_wider(id_cols = GEOID, names_from = variable,
                values_from = c(estimate, moe, universe, share, share_moe),
                names_glue = "{variable}__{.value}")
  readr::write_csv(wide, file.path(OUT_DIR, paste0(geo, "_data.csv")))

  # simplified display geometry, GEOID only, join happens in the browser
  gs <- ms_simplify(g[, "GEOID"], keep = SIMPLIFY_KEEP, keep_shapes = TRUE)
  st_write(gs, file.path(OUT_DIR, paste0(geo, "_geometry.geojson")),
           delete_dsn = TRUE, quiet = TRUE)

  invisible(long)
}

# --------------------------------------------------------------- run all ------
validate_codes()

results <- list()
for (geo in c("tract", "blockgroup", "puma", "borough")) {
  message("Processing ", geo)
  results[[geo]] <- pull_acs_level(geo)
}
message("Processing block (decennial)")
results[["block"]] <- pull_dec_block()

message("Processing nta (aggregated from tracts)")
nta_crosswalk <- build_nta_crosswalk()
results[["nta"]] <- aggregate_to_nta(results[["tract"]], nta_crosswalk)

for (geo in names(results)) {
  g <- load_boundary(geo)
  results[[geo]] <- attach_geometry_and_write(results[[geo]], geo, g)
}

# ------------------------------------------ variable dictionary for the map ---
var_json <- vars |>
  filter(id != "") |>
  transmute(id, group, label, type, decimals = as.integer(decimals),
            geos = str_split(geos, fixed("|")),
            universe_label, notes)
write_json(var_json, file.path(OUT_DIR, "variables.json"), auto_unbox = TRUE, pretty = TRUE)

meta <- list(generated = as.character(Sys.Date()),
             acs_release = paste0(ACS_YEAR - 4, "-", ACS_YEAR, " ", toupper(ACS_SURVEY)),
             decennial = paste0(DEC_YEAR, " Census ", toupper(DEC_SUMFILE)),
             geographies = names(results),
             note = "Shares use each variable's ACS universe. Medians and dollar values carry no share. Block level is 2020 decennial only.")
write_json(meta, file.path(OUT_DIR, "metadata.json"), auto_unbox = TRUE, pretty = TRUE)

# ---------------------------------------------- cross-check summary (audit) ---
message("\n==== CROSS-CHECK ====")
citywide_pop <- results[["borough"]] |> filter(variable == "total_pop") |> summarise(sum(estimate)) |> pull()
message("Citywide total population (should be ~8.3M): ", format(round(citywide_pop), big.mark=","))
for (geo in names(results)) {
  n <- results[[geo]] |> distinct(GEOID) |> nrow()
  message(sprintf("  %-11s %6d areas", geo, n))
}
message("Done. Outputs in ", normalizePath(OUT_DIR))
