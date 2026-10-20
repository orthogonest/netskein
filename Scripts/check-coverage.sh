#!/bin/bash

# Configure minimum coverage threshold (in percent)
MIN_COVERAGE=${MIN_COVERAGE_THRESHOLD:-80}

echo "📊 Calculating code coverage..."

# Run llvm-cov report to get a text summary (ONLY for the Sources folder)
COVERAGE_SUMMARY=$(xcrun llvm-cov report \
  .build/out/Products/Debug/NetSkeinTests.xctest/Contents/MacOS/NetSkeinTests \
  -instr-profile=.build/out/Products/Debug/codecov/default.profdata \
  Sources)

# Print the summary to CI logs for human readability
echo "$COVERAGE_SUMMARY"

# Extract the 'TOTAL' line and fetch the Lines Coverage percentage
TOTAL_LINE=$(echo "$COVERAGE_SUMMARY" | grep "TOTAL")

# Use awk to find the exact percentage column before the final dashes
TOTAL_PCT=$(echo "$TOTAL_LINE" | awk '{
  # Loop backwards from the end to find the first field containing a % sign
  for(i=NF; i>0; i--) {
    if($i ~ /%/) {
      print $i;
      exit;
    }
  }
}' | sed 's/%//')

# Convert to an integer for basic numeric comparison
TOTAL_INT=$(printf "%.0f" "$TOTAL_PCT")

echo "--------------------------------------"
echo "✅ Total Coverage Detected: $TOTAL_PCT%"
echo "🎯 Minimum CI Threshold: $MIN_COVERAGE%"
echo "--------------------------------------"

# Validate coverage sufficiency
if [ "$TOTAL_INT" -lt "$MIN_COVERAGE" ]; then
  echo "❌ FAILED: Code coverage ($TOTAL_PCT%) is below the minimum threshold ($MIN_COVERAGE%)!"
  exit 1
else
  echo "🚀 SUCCESS: Code coverage meets the minimum requirements."
  exit 0
fi
