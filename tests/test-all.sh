#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  gst-vf-metal - Full Test Suite"
echo "========================================="
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

# Run compositor tests
"${SCRIPT_DIR}/test-compositor.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run video sink tests
"${SCRIPT_DIR}/test-videosink.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run video filter tests
"${SCRIPT_DIR}/test-videofilter.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run convertscale tests
"${SCRIPT_DIR}/test-convertscale.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run transform tests
"${SCRIPT_DIR}/test-transform.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run deinterlace tests
"${SCRIPT_DIR}/test-deinterlace.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run overlay tests
"${SCRIPT_DIR}/test-overlay.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

# Run multi-element pipeline tests
"${SCRIPT_DIR}/test-multi-element.sh"
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
    TOTAL_PASS=$((TOTAL_PASS + 1))
fi

echo ""
echo "========================================="
echo "  All test suites: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed"
echo "========================================="

if [ ${TOTAL_FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
