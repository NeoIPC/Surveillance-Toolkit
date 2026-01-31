# Partner-Report Implementation Checklist

**Last Updated**: 2026-01-28 (Session Complete - All 9 tables rendering cleanly)

## Status Summary
✅ **COMPLETE**: All 9 Partner-Report tables implemented and rendering without errors
- All tables use `department_data` spanner (shown conditionally when reference data exists)
- All table-specific footnotes added to _sR.yaml with Partner-specific wording
- Formula footnotes correctly positioned inside has_reference blocks after tab_spanner calls
- Spanner references updated to "department_data" (changed from "own_unit")
- HTML output verified with zero errors

## Remaining Tasks
- [ ] **Manual review**: Check diffs before committing
- [ ] **CRITICAL**: Build and test Reference-Report (secondary BSI refactoring affects it)
- [ ] **Verification**: Check row ordering in all 9 Partner-Report tables matches Reference-Report
  - _tbl-risk-density-rates.qmd
  - _tbl-surgical-procedure-rates.qmd
  - _tbl-incidence-density-rates.qmd
  - _tbl-device-associated-incidence-density-rates.qmd
  - _tbl-infectious-agent-detection-rate.qmd
  - _tbl-agent-per-infection-rate.qmd
  - _tbl-abr-infection-rate.qmd
  - _tbl-secondary-bsi-rates.qmd
  - _tbl-resistance-test-rate.qmd
- [ ] **Verification**: Check all table captions are correct in Partner-Report

## Foundation (Step 1)
- [x] Add `is_neoipcr_dept_ds()` to neoipcr/R/obj-type.R
- [x] Add `is_scalar_neoipcr_dept_ds()` to neoipcr/R/obj-type.R
- [x] Add `is_neoipcr_bnch_ds()` to neoipcr/R/obj-type.R
- [x] Add `is_scalar_neoipcr_bnch_ds()` to neoipcr/R/obj-type.R
- [x] Add `check_neoipcr_dept_ds()` to neoipcr/R/types-check.R
- [x] Add `check_neoipcr_bnch_ds()` to neoipcr/R/types-check.R
- [x] Add validation to start of `get_benchmark_data()` in neoipcr/R/calc.R
- [x] Created `reports/common/helpers.R` for shared functions (format_integer)
- [x] Updated both Reference-Report and Partner-Report to source common helpers

## Table 1: Incidence Density Rates (Steps 2-6)
- [x] Refactor `get_incidence_density_rate_table()` - add `include_quartiles = TRUE` parameter
- [x] Verify join key is `inf_type`
- [x] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [x] Add handling block to `get_benchmark_data()`
- [x] Create Surveillance-Toolkit/reports/Partner-Report/tables/_tbl-incidence-density-rates.qmd
- [x] Include in Partner-Report.qmd
- [x] Fix format_integer scope issue (via common/helpers.R)
- [x] Verify localization structure (flat keys confirmed correct)
- [x] Test end-to-end rendering with fixes

## Table 2: Device-Associated Incidence
- [x] Uncomment in `calculate_department_data()`
- [x] Add handling block to `get_benchmark_data()` with full_join and NA/0 handling
- [x] Create _tbl-device-associated-incidence-density-rates.qmd with conditional rendering
- [x] Include in Partner-Report.qmd
- [x] Add rate_footnote to _sR.yaml
- [x] Test end-to-end rendering (HTML/DOCX successful)

## Table 3: Risk Density Rates
- [x] Create _tbl-risk-density-rates.qmd
- [x] Include in Partner-Report.qmd
- [x] Test end-to-end rendering

## Table 4: Infectious Agent Detection (by Agent)
- [x] Uncomment in `calculate_department_data()`
- [x] Add handling block to `get_benchmark_data()` with flexible column detection (any_of)
- [x] Create _tbl-agent-per-infection-rate.qmd
- [x] Include in Partner-Report.qmd
- [x] Add rate_footnote to _sR.yaml
- [x] Test end-to-end rendering

## Table 5: Antibiotic-Resistant Bacteria Infections
- [x] Uncomment in `calculate_department_data()`
- [x] Add handling block to `get_benchmark_data()` with flexible column detection
- [x] Create _tbl-abr-infection-rate.qmd
- [x] Include in Partner-Report.qmd
- [x] Add rate_footnote to _sR.yaml
- [x] Test end-to-end rendering

## Table 6: Infectious Agent Detection (by Infection Type)
- [x] Uncomment in `calculate_department_data()`
- [x] Add handling block to `get_benchmark_data()` with flexible column detection
- [x] Fix join column to use "inf" instead of "event_type_key"
- [x] Create _tbl-infectious-agent-detection-rate.qmd
- [x] Include in Partner-Report.qmd
- [x] Add rate_footnote to _sR.yaml
- [x] Test end-to-end rendering

## Table 7: Resistance Testing Rates
- [x] Uncomment in `calculate_department_data()`
- [x] Add handling block to `get_benchmark_data()` with flexible column detection
- [x] Create _tbl-resistance-test-rate.qmd
- [x] Include in Partner-Report.qmd
- [x] Add rate_footnote to _sR.yaml
- [x] Test end-to-end rendering

## Table 8: Secondary BSI Rates - REFACTORING REQUIRED
**Status**: Currently computed directly in QMD files - needs to follow standard neoipcr pattern

**Implementation Plan**:
- [x] Create helper function `get_secondary_bsi_rates(x, group_cols = NULL, use_cache = TRUE)` in neoipcr/R/calc.R
  - Calculate secondary BSI rates for infection types (nec, hap, ssi)
  - Support grouping by department when `group_cols = "department_key"`
  - Access: `x$events`, `x$infectiousAgentFindings`, `x$necData`, `x$pneumoniaData`, `x$ssiData`
  - Return: tibble with `event_type_key`, `n`, `rate` (per 100 infections with follow-up)
- [x] Create table function `get_secondary_bsi_rate_table(ref, use_cache = TRUE, include_quartiles = TRUE)` in neoipcr/R/calc.R
  - Follow pattern from `get_incidence_density_rate_table()`
  - Calculate pooled rates using `get_secondary_bsi_rates()`
  - Calculate quartiles from department-level rates when `include_quartiles = TRUE`
  - Return: tibble with `event_type_key`, `n`, `pooled`, `q1`, `q2`, `q3`
  - Key column: `event_type_key` (factor: "nec", "hap", "ssi")
  - **Quartile dropping logic**: YES - Drop when < 5 departments or low expected event counts
  - **Missing infection types**: INCLUDE - Add rows with n=0, pooled=0
- [x] Add to `calculate_reference_data()` after line ~165 (after abr_infection_rate_table)
- [x] Add to `calculate_department_data()` after line ~232 with `include_quartiles = FALSE`
- [x] Add handling block to `get_benchmark_data()` after line ~462 (join key: `event_type_key`)
- [x] Install updated neoipcr package
- [x] Update Reference-Report/_tbl-secondary-bsi-rates.qmd to use `neoipcr::get_secondary_bsi_rate_table()`
- [x] Update Partner-Report/_tbl-secondary-bsi-rates.qmd to use `benchmark_data$secondary_bsi_rate_table`
- [x] Add localization section to common.yaml: `tbl-secondary-bsi-rates` with keys:
  - tbl-cap, rate_name, rate_numerator, rate_denominator
  - n_footnote, rate_footnote, pooled_footnote, quartile_footnote, no_data
  - nec, hap, ssi (infection type labels)
- [x] Fix join_by syntax error (cannot use tidyselect::all_of inside join_by)
- [x] Reinstall updated neoipcr package
- [x] Test end-to-end rendering - VERIFIED: Table appears in HTML output

## All 9 Tables Complete - 2026-01-28
- [x] Table 1: Risk Density Rates (_tbl-risk-density-rates.qmd)
- [x] Table 2: Surgical Procedure Rates (_tbl-surgical-procedure-rates.qmd)
- [x] Table 3: Incidence Density Rates (_tbl-incidence-density-rates.qmd)
- [x] Table 4: Device-Associated Incidence (_tbl-device-associated-incidence-density-rates.qmd)
- [x] Table 5: Infectious Agent Detection by Infection (_tbl-infectious-agent-detection-rate.qmd)
- [x] Table 6: Infectious Agent Detection by Agent (_tbl-agent-per-infection-rate.qmd)
- [x] Table 7: Antibiotic-Resistant Infections (_tbl-abr-infection-rate.qmd)
- [x] Table 8: Secondary BSI Rates (_tbl-secondary-bsi-rates.qmd)
- [x] Table 9: Resistance Testing Rates (_tbl-resistance-test-rate.qmd)

## Recent Fixes (2026-01-28 Session)
- [x] Added `department_data: "Your data"` to _sR.yaml
- [x] Added department_data spanner to all 9 tables (conditional when reference data exists)
- [x] Added all table-specific footnotes to _sR.yaml (n_footnote, rate_footnote for all 9 tables)
- [x] Fixed spanner footnote positioning in 6 tables (must come AFTER tab_spanner call)
- [x] Removed backticks from rate_name, rate_numerator, rate_denominator keys in 2 tables
- [x] Fixed broken pipe chains (removed duplicate `tbl <- tbl |>` statements)
- [x] **FINAL FIX**: Moved formula footnotes inside has_reference blocks for 3 tables:
  - _tbl-device-associated-incidence-density-rates.qmd
  - _tbl-infectious-agent-detection-rate.qmd
  - _tbl-resistance-test-rate.qmd
  - Changed spanner reference from "own_unit" to "department_data"
  - Positioned footnotes AFTER department_data spanner creation
- [x] Verified HTML renders cleanly with **zero errors**

## Known Issues
- **Table 6 row ordering**: Row order appears incorrect and may not match Reference-Report (possibly affects other tables too)
- **Table 4 caption**: Caption text is incorrect

## Notes

### Implementation Strategy
- Work on tables incrementally: refactor → uncomment → benchmark → report → test
- Validate each table before moving to the next
- Keep complexity manageable within session budget
- Prioritize completing at least incidence + device-associated tables

### Key Design Decisions
- Use `include_quartiles` parameter to reduce complexity in table functions
- Department data uses benchmark structure (neoipcr_bnch_ds) for side-by-side comparison
- Reference data loaded via JSON file parameter (ReferenceDataFile)
- No private function usage in production _setup.qmd

### Cross-Repository Dependencies
- **neoipcr** (R library): Core calculation functions and data structures
- **Surveillance-Toolkit** (Reports): Quarto templates consuming neoipcr output
- Both repos on PartnerReport branch for coordinated development
