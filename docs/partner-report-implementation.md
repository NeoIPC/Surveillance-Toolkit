# Partner-Report Implementation Checklist

**Last Updated**: 2026-01-27 (Session notes in `docs/session-notes-2026-01-27.md`)

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
- [ ] Test end-to-end rendering with fixes

## Table 2: Device-Associated Incidence
- [ ] Refactor `get_dev_ass_incidence_density_rate_table()` - add `include_quartiles = TRUE`
- [ ] Verify join key is `dev`
- [ ] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [ ] Add handling block to `get_benchmark_data()`
- [ ] Create _tbl-dev-ass-incidence-density-rates.qmd
- [ ] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering

## Table 3: Risk Density Rates
- [x] Create _tbl-risk-density-rates.qmd
- [x] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering (verify format_integer works)

## Table 4: Infectious Agent Detection (by Agent)
- [ ] Refactor `get_infectious_agent_detection_rate_per_agent_table()` - add `include_quartiles = TRUE`
- [ ] Verify join key (TBD - investigate function)
- [ ] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [ ] Add handling block to `get_benchmark_data()`
- [ ] Create _tbl-infectious-agent-per-agent.qmd
- [ ] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering

## Table 5: Antibiotic-Resistant Bacteria Infections
- [ ] Refactor `get_abr_infection_rate_table()` - add `include_quartiles = TRUE`
- [ ] Verify join key is `abr_type`
- [ ] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [ ] Add handling block to `get_benchmark_data()`
- [ ] Create _tbl-abr-infection-rates.qmd
- [ ] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering

## Table 6: Infectious Agent Detection (by Infection Type)
- [ ] Refactor `get_infectious_agent_detection_rate_per_inf_type_table()` - add `include_quartiles = TRUE`
- [ ] Verify join key (TBD - investigate function)
- [ ] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [ ] Add handling block to `get_benchmark_data()`
- [ ] Create _tbl-infectious-agent-per-inf-type.qmd
- [ ] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering

## Table 7: Resistance Testing Rates
- [ ] Refactor `get_resistance_test_rate_table()` - add `include_quartiles = TRUE`
- [ ] Verify join key (TBD - investigate function)
- [ ] Uncomment in `calculate_department_data()` with `include_quartiles = FALSE`
- [ ] Add handling block to `get_benchmark_data()`
- [ ] Create _tbl-resistance-test-rates.qmd
- [ ] Include in Partner-Report.qmd
- [ ] Test end-to-end rendering

## Final Steps
- [ ] Clean up _setup.qmd (remove test code if any)
- [ ] Test with provided JSON reference data
- [ ] Review all Partner-Report tables for consistency
- [ ] Consider German translation file updates
- [ ] Merge PartnerReport branches to main (both repos)

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
