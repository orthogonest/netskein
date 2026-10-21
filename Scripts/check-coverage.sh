#!/bin/bash

# Configure minimum coverage threshold (in percent)
MIN_COVERAGE=${MIN_COVERAGE_THRESHOLD:-90}

# --- ANSI ESCAPE CODES FOR PROFESSIONAL TEXT STYLING ---
# Text Styles
BOLD="\033[1m"
UNDERLINE="\033[4m"
RESET="\033[0m"

# Text Colors
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"

echo -e "${BOLD}${CYAN}Calculating code coverage...${RESET}"

# --- DYNAMIC PATH RESOLUTION ---
# Find the compiled test binary within the .build directory automatically
TEST_BINARY=$(find .build -type f -perm +111 -name "*Tests" | grep -v "\.dSYM" | grep -v "\.json" | head -n 1)

# Dynamically find the actual .profdata file inside the build directory
PROFDATA_PATH=$(find .build -type f -name "*.profdata" | head -n 1)

# Fallback: If no .profdata is found via find, use swift built-in command and swap extension
if [ -z "$PROFDATA_PATH" ]; then
  SWIFT_PATH=$(swift test --show-codecov-path)
  PROFDATA_PATH="${SWIFT_PATH%.*}.profdata"
fi

echo "Test binary found at: $TEST_BINARY"
echo "Profile data found at: $PROFDATA_PATH"
echo "---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

# Run llvm-cov report to get a text summary (ONLY for the Sources folder)
COVERAGE_SUMMARY=$(xcrun llvm-cov report \
  "$TEST_BINARY" \
  -instr-profile="$PROFDATA_PATH" \
  Sources)

# Print the summary to CI logs for human readability
echo "$COVERAGE_SUMMARY"

# Extract the 'TOTAL' line and fetch the Lines Coverage percentage
TOTAL_LINE=$(echo "$COVERAGE_SUMMARY" | grep "TOTAL")

# Use awk to find the exact percentage column before the final dashes
TOTAL_PCT=$(echo "$TOTAL_LINE" | awk '{
  for(i=NF; i>0; i--) {
    if($i ~ /%/) {
      print $i;
      exit;
    }
  }
}' | sed 's/%//')

# Convert to an integer for basic numeric comparison
TOTAL_INT=$(printf "%.0f" "$TOTAL_PCT")

# Default to yellow if they are exactly equal
PCT_COLOR=$YELLOW

# Check if total coverage is strictly greater than minimum threshold
IS_GREATER=$(echo "$TOTAL_PCT > $MIN_COVERAGE" | bc -l)
# Check if total coverage is strictly less than minimum threshold
IS_LESS=$(echo "$TOTAL_PCT < $MIN_COVERAGE" | bc -l)

if [ "$IS_GREATER" -eq 1 ]; then
  PCT_COLOR=$GREEN
elif [ "$IS_LESS" -eq 1 ]; then
  PCT_COLOR=$RED
fi

echo "--------------------------------------"
printf "${BOLD}%-25s${RESET} %s%%\n" "Minimum CI Threshold:" "$MIN_COVERAGE"
printf "${BOLD}%-25s${RESET} ${BOLD}${PCT_COLOR}%s%%${RESET}\n" "Total Coverage Detected:" "$TOTAL_PCT"
echo "--------------------------------------"

# Validate coverage sufficiency
if [ "$TOTAL_INT" -lt "$MIN_COVERAGE" ]; then
  echo -e "${BOLD}${RED}FAILURE:${RESET} Code coverage (${TOTAL_PCT}%) is below the minimum threshold (${MIN_COVERAGE}%)!"
  exit 1
else
  echo -e "${BOLD}${GREEN}SUCCESS:${RESET} Code coverage meets the minimum requirements."
  exit 0
fi
