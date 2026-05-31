# Unit Test Implementation Plan: Infectious Agent Detection Rate Functions

**Created**: 2026-01-30
**Target Functions**: 
- `get_infectious_agent_detection_rates()`
- `get_infectious_agent_detection_rates_with_department_quartiles()`

**Location**: [neoipcr/R/calc.R](../../neoipcr/R/calc.R)

## Objective

Create a comprehensive unit test that verifies `get_infectious_agent_detection_rates()` and `get_infectious_agent_detection_rates_with_department_quartiles()` return matching data for shared columns across multiple grouping scenarios, while confirming each function has its expected unique columns.

## Test File Location

**Create**: [neoipcr/tests/testthat/test-calc.R](../../neoipcr/tests/testthat/test-calc.R)

## Implementation Steps

### Step 1: Create Test File Structure

Create `test-calc.R` in `neoipcr/tests/testthat/` with the following structure:

```r
# Tests for calculation functions in calc.R

library(testthat)
library(neoipcr)
library(dplyr)

# Helper function to create mock neoipcr_ds dataset
create_mock_dataset <- function() {
  # Implementation in Step 2
}

# Test suite for infectious agent detection rate functions
test_that("get_infectious_agent_detection_rates functions return consistent shared columns", {
  # Implementation in Steps 3-5
})
```

### Step 2: Build Realistic Mock Dataset

Create a helper function `create_mock_dataset()` that returns a mock `neoipcr_ds` object with:

#### 2.1 Patients Data
- 50-70 patients across 5-7 departments
- Patient keys: `"P001"` through `"P070"`
- Department keys: `"DEPT_A"`, `"DEPT_B"`, `"DEPT_C"`, `"DEPT_D"`, `"DEPT_E"`, `"DEPT_F"`, `"DEPT_G"`

#### 2.2 Enrollments Data
- One enrollment per patient
- Enrollment keys: `"E001"` through `"E070"`
- Link patients to departments
- Enrollment dates spanning 1-12 months

#### 2.3 Events Data (Infections)
- 80-120 infection events across departments
- Event keys: `"INF001"` through `"INF120"`
- Event types: `"cauti"`, `"clabsi"`, `"vap"` (2-3 types to test grouping)
- Mix of events across:
  - Different departments (ensure 5+ departments have data for quartile calculation)
  - Different infection types
  - Realistic distribution (some departments more than others)

#### 2.4 InfectiousAgentFindings Data
- 150-250 pathogen detections linked to infection events
- Finding keys: `"IAF001"` through `"IAF250"`
- Pathogen keys: `"PATH_ECOLI"`, `"PATH_KLEB"`, `"PATH_STAPH"`, `"PATH_PSEUDO"`, etc.
- Multiple pathogens per infection for some events (realistic scenario)
- Not all infections have pathogen findings (some with zero, some with 1-3)

#### 2.5 Pathogen Taxonomy Data
- Pathogen definitions matching the pathogen keys used in InfectiousAgentFindings
- Include taxonomy columns:
  - `input_id`: Pathogen key
  - `input_name`: Pathogen display name
  - `output_id`: Pathogen key (same as input_id for simplicity)
  - `genus`: `"Escherichia"`, `"Klebsiella"`, `"Staphylococcus"`, `"Pseudomonas"` (3-4 genera)
  - `family`, `order`, etc. (optional, for completeness)

#### 2.6 Mock Object Structure
```r
create_mock_dataset <- function() {
  # Create all data frames as described above
  
  mock_ds <- list(
    patients = patients_df,
    enrollments = enrollments_df,
    events = events_df,
    infectiousAgentFindings = findings_df,
    pathogenTaxonomy = taxonomy_df,
    # Add other required components as empty tibbles if needed
    necData = tibble::tibble(),
    pneumoniaData = tibble::tibble(),
    ssiData = tibble::tibble()
  )
  
  # Set class attributes to simulate neoipcr_ds
  class(mock_ds) <- c("neoipcr_ds", "list")
  
  return(mock_ds)
}
```

**Key Considerations for Mock Data**:
- Ensure at least 5 departments have sufficient data for quartile calculations
- Create varied pathogen detection patterns (some infections with 0, 1, 2, or 3+ pathogens)
- Mix event types across departments (not all departments have all event types)
- Include edge cases: departments with only 1-2 infections, genera with low detection counts

### Step 3: Test Setup - Create Test Cases

Define four test scenarios with different `group_cols` parameters:

```r
test_cases <- list(
  list(
    name = "No grouping (overall pooled rates)",
    group_cols = NULL
  ),
  list(
    name = "Grouped by event type",
    group_cols = "event_type_key"
  ),
  list(
    name = "Grouped by genus",
    group_cols = "genus"
  ),
  list(
    name = "Grouped by event type and genus",
    group_cols = c("event_type_key", "genus")
  )
)
```

### Step 4: Main Test Logic - Compare Function Outputs

For each test case, implement the following comparison logic:

```r
for (tc in test_cases) {
  # 4.1 Call both functions with identical parameters
  result_base <- get_infectious_agent_detection_rates(
    x = mock_ds,
    group_cols = tc$group_cols,
    use_cache = FALSE
  )
  
  result_quartiles <- get_infectious_agent_detection_rates_with_department_quartiles(
    x = mock_ds,
    group_cols = tc$group_cols,
    use_cache = FALSE
  )
  
  # 4.2 Sort both results by grouping columns to ensure consistent ordering
  if (!is.null(tc$group_cols)) {
    result_base <- result_base |>
      arrange(across(all_of(tc$group_cols)))
    
    result_quartiles <- result_quartiles |>
      arrange(across(all_of(tc$group_cols)))
  }
  
  # 4.3 Extract shared columns (n, rate) for comparison
  shared_cols <- c(tc$group_cols, "n", "rate")
  
  base_shared <- result_base |>
    select(all_of(shared_cols))
  
  quartiles_shared <- result_quartiles |>
    select(all_of(shared_cols))
  
  # 4.4 Compare shared columns - they must match exactly
  expect_equal(
    base_shared,
    quartiles_shared,
    info = paste("Shared columns must match for test case:", tc$name)
  )
}
```

### Step 5: Column Presence Verification

Verify each function returns its expected unique columns:

```r
# 5.1 Verify base function has unique columns
base_unique_cols <- c("inf_with_pathogen", "total_inf", "n_per_t", "iwp_per_t")

for (col in base_unique_cols) {
  expect_true(
    col %in% names(result_base),
    info = paste("Base function must include column:", col)
  )
  
  expect_false(
    col %in% names(result_quartiles),
    info = paste("Quartile function must NOT include column:", col)
  )
}

# 5.2 Verify quartile function has unique columns
quartile_unique_cols <- c("q1", "q2", "q3", "drop_quartiles")

for (col in quartile_unique_cols) {
  expect_true(
    col %in% names(result_quartiles),
    info = paste("Quartile function must include column:", col)
  )
  
  expect_false(
    col %in% names(result_base),
    info = paste("Base function must NOT include column:", col)
  )
}
```

## Expected Column Structure

### Base Function: `get_infectious_agent_detection_rates()`

**Returns**:
- All `group_cols` (if specified)
- `n`: Number of pathogen detections
- `rate`: Rate per 100 infections with pathogen (alias for `n_per_iwp`)
- `n_per_iwp`: Primary rate metric (per 100 infections with pathogen)
- `inf_with_pathogen`: Number of infections with pathogen detected
- `total_inf`: Total number of infections
- `n_per_t`: Rate per 100 total infections
- `iwp_per_t`: Percentage of infections with pathogen

### Quartile Function: `get_infectious_agent_detection_rates_with_department_quartiles()`

**Returns**:
- All `group_cols` (if specified)
- `n`: Number of pathogen detections (pooled)
- `rate`: Rate per 100 infections with pathogen (pooled, same as `n_per_iwp`)
- `q1`, `q2`, `q3`: Quartile values (25th, 50th, 75th percentiles)
- `drop_quartiles`: Boolean flag (TRUE when quartiles suppressed due to <5 departments or low counts)

## Test Validation Criteria

### ✅ Success Criteria

1. **Shared column values match exactly** between both functions for:
   - `n` (count)
   - `rate` (primary metric)
   - All grouping columns

2. **Column presence verified**:
   - Base function has 4 unique columns NOT in quartile function
   - Quartile function has 4 unique columns NOT in base function

3. **Row ordering consistent** after sorting by grouping columns

4. **Multiple grouping scenarios pass**:
   - NULL grouping (overall)
   - Single dimension grouping (event type OR genus)
   - Multi-dimension grouping (event type AND genus)

### ❌ Failure Indicators

- `expect_equal()` fails for shared columns → Functions calculating different values
- Column presence checks fail → Column structure changed unexpectedly
- Test fails for specific grouping → Edge case in join or aggregation logic

## Running the Tests

### Execute Test File
```powershell
# From neoipcr package root
Rscript -e "testthat::test_file('tests/testthat/test-calc.R')"
```

### Execute All Tests
```powershell
# From neoipcr package root
Rscript -e "devtools::test()"
```

### Expected Output
```
Test passed 🎉

✓ | F W S  OK | Context
✓ |         4 | test-calc

══ Results ═════════════════════════════════════════════════════════════════════
Duration: X.X s

[ FAIL 0 | WARN 0 | SKIP 0 | PASS 4 ]
```

## Future Enhancements

### Additional Test Coverage (Optional)

1. **Caching behavior**: Test with `use_cache = TRUE` on second call
2. **Edge cases**:
   - Dataset with <5 departments (quartiles should drop)
   - Dataset with zero pathogen detections
   - Single department (quartiles should drop)
   - Missing taxonomy data for some pathogens
3. **Rate calculation validation**: Manually calculate expected rates for small dataset and verify exact values
4. **Quartile dropping logic**: Explicitly test `drop_quartiles` flag behavior

## Dependencies

### Required Packages
- `testthat` (testing framework)
- `dplyr` (data manipulation in tests)
- `tibble` (for creating mock data frames)
- `neoipcr` (package under test)

### Function Dependencies
The functions being tested depend on:
- `get_pathogen_taxonomy()` - Called internally to map pathogen IDs to taxonomy
- `get_infection_counts()` - Helper function to calculate infection denominators
- Standard dplyr operations: `left_join`, `summarise`, `group_by`, `arrange`

## Implementation Checklist

- [ ] Create [test-calc.R](../../neoipcr/tests/testthat/test-calc.R)
- [ ] Implement `create_mock_dataset()` helper with realistic data
- [ ] Define four test case scenarios
- [ ] Implement main test logic with shared column comparison
- [ ] Add column presence verification
- [ ] Run test file and verify all pass
- [ ] Document any edge cases discovered during testing
- [ ] (Optional) Add additional test coverage for caching and edge cases

## Notes

### Browser() Calls
The functions currently contain `browser()` calls at:
- Line 1857 in `get_infectious_agent_detection_rates_with_department_quartiles()`
- Line 1943 in `get_infectious_agent_detection_rates()`

**Action**: These are debugging leftovers and should be removed before implementing the tests.

### Test Philosophy
This test focuses on **consistency verification** between two related functions, not comprehensive validation of calculation correctness. It ensures that when the same input is provided, both functions agree on the shared output columns (`n`, `rate`) regardless of their different internal calculation approaches (direct calculation vs. department-level quartile calculation).

### Known Limitations
- Mock data may not capture all real-world edge cases
- Test does not validate absolute correctness of rate calculations (only consistency)
- Quartile dropping logic is not explicitly tested (only that quartile columns exist/don't exist)
