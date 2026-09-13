#!/bin/sh
# Fixture-only effective configuration tests. No mirakc process or USB device
# is started; all hardware state is represented by a siano-ts --list fixture.
set -eu

LC_ALL=C
export LC_ALL
CDPATH=
export CDPATH

script_dir=$(cd "$(dirname "$0")" && pwd)
addon_dir=$(cd "$script_dir/.." && pwd)
helper=$addon_dir/generate-effective-config.py
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mirakc-effective-config-test.XXXXXX")

cleanup()
{
    rm -rf "$tmp_dir" || :
}

trap cleanup EXIT HUP INT TERM

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains()
{
    needle=$1
    file=$2
    description=$3
    grep -Fq "$needle" "$file" || fail "$description: missing [$needle]"
}

assert_tuners()
{
    file=$1
    expected_siano=$2
    expected_q3u4=$3
    expected_custom=$4
    description=$5
    python3 - "$file" "$expected_siano" "$expected_q3u4" "$expected_custom" "$description" <<'PY'
import sys
import yaml

path, expected_siano, expected_q3u4, expected_custom, description = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
tuners = config.get("tuners", [])
siano = [t for t in tuners if "/usr/local/bin/px-s1ud-stream" in t.get("command", "")]
q3u4 = [t for t in tuners if "/usr/local/bin/px4-ts-stream" in t.get("command", "")]
custom = [t for t in tuners if t.get("command") == "/usr/local/bin/custom-tuner {{{channel}}}"]
actual = (len(siano), len(q3u4), len(custom))
expected = tuple(map(int, (expected_siano, expected_q3u4, expected_custom)))
if actual != expected:
    raise SystemExit(f"{description}: expected {expected}, got {actual}")
PY
}

assert_channels()
{
    file=$1
    expected_gr=$2
    expected_bs=$3
    expected_cs=$4
    description=$5
    python3 - "$file" "$expected_gr" "$expected_bs" "$expected_cs" "$description" <<'PY'
import sys
import yaml

path, expected_gr, expected_bs, expected_cs, description = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
channels = config.get("channels", [])
counts = {channel_type: 0 for channel_type in ("GR", "BS", "CS")}
for channel in channels:
    if isinstance(channel, dict) and channel.get("type") in counts:
        counts[channel["type"]] += 1
actual = (counts["GR"], counts["BS"], counts["CS"])
expected = tuple(map(int, (expected_gr, expected_bs, expected_cs)))
if actual != expected:
    raise SystemExit(f"{description}: expected {expected}, got {actual}")
PY
}

write_base_config()
{
    base=$1
    cp "$addon_dir/config.yml.template" "$base"
    python3 - "$base" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
config["tuners"].append({
    "name": "custom tuner",
    "types": ["GR"],
    "command": "/usr/local/bin/custom-tuner {{{channel}}}",
})
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False, allow_unicode=True)
PY
}

run_helper()
{
    input=$1
    output=$2
    list=$3
    warmup=$4
    q3u4=$5
    log=$6
    if ! python3 "$helper" \
        --input "$input" \
        --output "$output" \
        --siano-list "$list" \
        --warmup-file "$warmup" \
        --q3u4-enabled "$q3u4" \
        >"$log.stdout" 2>"$log.stderr"; then
        return 1
    fi
}

assert_no_temp_files()
{
    directory=$1
    pattern=$2
    [ -z "$(find "$directory" -maxdepth 1 -type f -name "$pattern" -print)" ] || \
        fail "temporary effective config remained in $directory"
}

base=$tmp_dir/base.yml
write_base_config "$base"

q3_zero=$tmp_dir/q3-zero.yml
q3_zero_list=$tmp_dir/q3-zero.list
printf '%s\n' '0 devices' > "$q3_zero_list"
q3_zero_hash=$(sha256sum "$base" | awk '{print $1}')
run_helper "$base" "$q3_zero" "$q3_zero_list" "$tmp_dir/q3-zero.warmup" 1 "$tmp_dir/q3-zero.log" || \
    fail 'Q3U4 plus zero Siano generation failed'
[ -f "$q3_zero" ] && [ ! -L "$q3_zero" ] || fail 'effective config is not a regular file'
assert_tuners "$q3_zero" 0 8 1 'Q3U4 plus zero Siano tuner counts'
assert_channels "$q3_zero" 11 1 1 'Q3U4 plus zero Siano channel counts'
[ ! -s "$tmp_dir/q3-zero.warmup" ] || fail 'zero Siano case warmed an adapter'
assert_equal_hash=$(sha256sum "$base" | awk '{print $1}')
[ "$q3_zero_hash" = "$assert_equal_hash" ] || fail 'user config changed in zero Siano case'
assert_contains 'detected_siano=none' "$tmp_dir/q3-zero.log.stderr" 'zero Siano summary'
assert_contains 'q3u4=enabled' "$tmp_dir/q3-zero.log.stderr" 'Q3U4 enabled summary'

q3_absent=$tmp_dir/q3-absent.yml
q3_absent_list=$tmp_dir/q3-absent.list
cat > "$q3_absent_list" <<'EOF'
0: 3275:0080 supported
1: 3275:0080 supported
2 supported RIO device(s), 2 known Siano device(s)
EOF
run_helper "$base" "$q3_absent" "$q3_absent_list" "$tmp_dir/q3-absent.warmup" 0 "$tmp_dir/q3-absent.log" || \
    fail 'Q3U4 absent plus two Siano generation failed'
assert_tuners "$q3_absent" 2 0 1 'Q3U4 absent tuner counts'
assert_channels "$q3_absent" 11 0 0 'Q3U4 absent channel counts'
actual_warmup=$(cat "$tmp_dir/q3-absent.warmup")
expected_warmup=$(printf '0\n1')
[ "$actual_warmup" = "$expected_warmup" ] || fail 'both retained Siano adapters were not selected for warmup'

q3_one=$tmp_dir/q3-one.yml
q3_one_list=$tmp_dir/q3-one.list
cat > "$q3_one_list" <<'EOF'
0: 3275:0080 supported
-: 187f:0010 Siano Stellar ROM (unsupported)
1 supported RIO device(s), 2 known Siano device(s)
EOF
run_helper "$base" "$q3_one" "$q3_one_list" "$tmp_dir/q3-one.warmup" 1 "$tmp_dir/q3-one.log" || \
    fail 'Q3U4 plus one Siano generation failed'
assert_tuners "$q3_one" 1 8 1 'Q3U4 plus one Siano tuner counts'
assert_channels "$q3_one" 11 1 1 'Q3U4 plus one Siano channel counts'
actual_warmup=$(cat "$tmp_dir/q3-one.warmup")
[ "$actual_warmup" = 0 ] || fail 'only retained Siano adapter 0 was not selected for warmup'

q3_rejected=$tmp_dir/q3-rejected.yml
run_helper "$base" "$q3_rejected" "$q3_zero_list" "$tmp_dir/q3-rejected.warmup" 0 "$tmp_dir/q3-rejected.log" || \
    fail 'firmware rejection case generation failed'
assert_tuners "$q3_rejected" 0 0 1 'Q3U4 firmware rejection tuner counts'
assert_channels "$q3_rejected" 11 0 0 'Q3U4 firmware rejection channel counts'

custom_satellite=$tmp_dir/custom-satellite.yml
cp "$base" "$custom_satellite"
python3 - "$custom_satellite" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
config["tuners"].append({
    "name": "custom satellite tuner",
    "types": ["BS", "CS"],
    "command": "/usr/local/bin/custom-satellite {{{channel}}}",
})
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False, allow_unicode=True)
PY
run_helper "$custom_satellite" "$tmp_dir/custom-satellite.effective.yml" "$q3_zero_list" \
    "$tmp_dir/custom-satellite.warmup" 0 "$tmp_dir/custom-satellite.log" || \
    fail 'custom BS/CS tuner generation failed'
assert_channels "$tmp_dir/custom-satellite.effective.yml" 11 1 1 \
    'custom BS/CS tuner channel counts'

arbitrary_channel=$tmp_dir/arbitrary-channel.yml
cp "$base" "$arbitrary_channel"
python3 - "$arbitrary_channel" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
config["channels"].append({"name": "unsupported channel", "type": "X"})
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False, allow_unicode=True)
PY
run_helper "$arbitrary_channel" "$tmp_dir/arbitrary-channel.effective.yml" "$q3_zero_list" \
    "$tmp_dir/arbitrary-channel.warmup" 1 "$tmp_dir/arbitrary-channel.log" || \
    fail 'unsupported channel generation failed'
assert_channels "$tmp_dir/arbitrary-channel.effective.yml" 11 1 1 \
    'unsupported channel counts'
if grep -Fq 'unsupported channel' "$tmp_dir/arbitrary-channel.effective.yml"; then
    fail 'unsupported channel type was retained without a matching tuner'
fi

run_invalid_case()
{
    name=$1
    content=$2
    input=$tmp_dir/$name.yml
    output=$tmp_dir/$name.effective.yml
    list=$tmp_dir/$name.list
    warmup=$tmp_dir/$name.warmup
    log=$tmp_dir/$name.log
    printf '%s\n' "$content" > "$input"
    printf '%s\n' '0 devices' > "$list"
    printf '%s\n' 'stale effective config' > "$output"
    if run_helper "$input" "$output" "$list" "$warmup" 1 "$log"; then
        fail "$name unexpectedly succeeded"
    fi
    [ ! -e "$output" ] || fail "$name left a stale effective config"
    [ ! -e "$warmup" ] || fail "$name left a warmup file"
    assert_no_temp_files "$tmp_dir" ".$name.effective.yml.*"
}

run_invalid_case managed_missing_index \
    'tuners: [{name: managed, command: /usr/local/bin/px4-ts-stream {{{channel}}}}]'
run_invalid_case managed_invalid_receiver \
    'tuners: [{name: managed, command: "env PX4_RECEIVER=8 /usr/local/bin/px4-ts-stream {{{channel}}}"}]'
run_invalid_case managed_invalid_siano \
    'tuners: [{name: managed, command: "env PX_S1UD_ADAPTER=-1 /usr/local/bin/px-s1ud-stream {{{channel}}}"}]'
run_invalid_case malformed_yaml \
    'tuners: [this is not valid YAML'
run_invalid_case no_tuners \
    'server: {}'
run_invalid_case malformed_channels_mapping "$(printf '%s\n' \
    'channels: {}' \
    'tuners: [{name: custom, command: /usr/local/bin/custom-tuner {{{channel}}}}]')"

run_invalid_list_case()
{
    name=$1
    list_content=$2
    input=$tmp_dir/$name.yml
    output=$tmp_dir/$name.effective.yml
    list=$tmp_dir/$name.list
    warmup=$tmp_dir/$name.warmup
    log=$tmp_dir/$name.log
    cp "$base" "$input"
    printf '%s\n' "$list_content" > "$list"
    printf '%s\n' 'stale effective config' > "$output"
    if run_helper "$input" "$output" "$list" "$warmup" 1 "$log"; then
        fail "$name unexpectedly succeeded"
    fi
    [ ! -e "$output" ] || fail "$name left a stale effective config"
    assert_no_temp_files "$tmp_dir" ".$name.effective.yml.*"
}

run_invalid_list_case numeric_unsupported_id \
    '0: 187f:0010 Siano Stellar ROM (unsupported)
1 supported RIO device(s), 1 known Siano device(s)'
run_invalid_list_case dashed_supported_id \
    '-: 3275:0080 Siano Rio (ISDB-T)
0 supported RIO device(s), 1 known Siano device(s)'
run_invalid_list_case non_contiguous_indices \
    '1: 3275:0080 Siano Rio (ISDB-T)
0: 187f:0600 Siano Rio (ISDB-T)
2 supported RIO device(s), 2 known Siano device(s)'

custom_data=$tmp_dir/custom-data.yml
cat > "$custom_data" <<'EOF'
tuners:
  - name: command data
    command: /bin/echo /usr/local/bin/px4-ts-stream
EOF
run_helper "$custom_data" "$tmp_dir/custom-data.effective.yml" "$q3_zero_list" \
    "$tmp_dir/custom-data.warmup" 1 "$tmp_dir/custom-data.log" || \
    fail 'wrapper path used as custom command data was misclassified'
python3 - "$tmp_dir/custom-data.effective.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
if config["tuners"] != [{"name": "command data", "command": "/bin/echo /usr/local/bin/px4-ts-stream"}]:
    raise SystemExit("wrapper path in custom command data was not preserved")
if "channels" in config:
    raise SystemExit("absent channels key was invented")
PY

echo 'PASS: effective config fixtures'
