#!/usr/bin/env bash
#
# mayhem/test.sh — RUN peercoin's own boost unit tests (built by mayhem/build.sh with normal flags).
# Each suite is run on its own and must pass its assertions (known-answer vectors: base58/bech32/
# hashes/keys/sighash/scripts/serialization/...). Suites that fail upstream on this tree are not listed:
# TestChain100Setup asserts a Bitcoin genesis-derived tip hash that Peercoin's chain does not satisfy,
# which aborts every suite whose fixture builds the 100-block chain (argsman, transaction, util,
# validation, txindex, ... tests).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped" "$pending" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/mayhem/build-test/src/test/test_peercoin"
[ -x "$RUNNER" ] || { echo "missing $RUNNER — mayhem/build.sh should have built it" >&2; emit_ctrf boost-test 0 1; exit 1; }

SUITES="addrman_tests allocator_tests amount_tests arith_uint256_tests banman_tests base32_tests
base58_tests base64_tests bech32_tests bip32_tests blockchain_tests blockencodings_tests
blockfilter_tests blockmanager_tests bloom_tests bswap_tests checkqueue_tests coins_tests
compilerbug_tests compress_tests crypto_tests cuckoocache_tests dbwrapper_tests denialofservice_tests
descriptor_tests flatfile_tests fs_tests getarg_tests hash_tests headers_sync_chainwork_tests
httpserver_tests i2p_tests key_io_tests key_tests logging_tests mempool_tests merkle_tests
merkleblock_tests miner_tests miniscript_tests minisketch_tests multisig_tests net_peer_eviction_tests
net_tests netbase_tests orphanage_tests pmt_tests pow_tests prevector_tests raii_event_tests
random_tests rest_tests result_tests reverselock_tests rpc_tests sanity_tests scheduler_tests
script_p2sh_tests script_parse_tests script_segwit_tests script_standard_tests script_tests
scriptnum_tests serfloat_tests serialize_tests settings_tests sighash_tests sigopcount_tests
skiplist_tests sock_tests streams_tests sync_tests system_tests timedata_tests torcontrol_tests
translation_tests txreconciliation_tests txrequest_tests uint256_tests util_threadnames_tests
validation_block_tests validation_flush_tests validationinterface_tests"

passed=0; failed=0
for s in $SUITES; do
  out=$("$RUNNER" --run_test="$s" --report_level=short 2>&1); rc=$?
  # Boost prints "Running N test case(s)..." and, on success, "Test module ... has passed with:".
  n=$(printf '%s\n' "$out" | sed -n 's/^Running \([0-9][0-9]*\) test case.*/\1/p' | head -1)
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" -gt 0 ] && printf '%s\n' "$out" | grep -q 'has passed with'; then
    passed=$((passed + n))
  else
    failed=$((failed + 1)); echo "FAILED suite $s (rc=$rc)" >&2; printf '%s\n' "$out" | tail -5 >&2
  fi
done
emit_ctrf boost-test "$passed" "$failed" 0
