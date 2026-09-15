function add_profile(profile_file, profile_type, line) {
    added_lines = 0
    while ((getline line < profile_file) > 0) {
        print line
        added_lines++
    }
    close(profile_file)
    if (added_lines == 0) {
        print "recorded-audio-profile: profile fragment is empty: " profile_file > "/dev/stderr"
        invalid = 1
    } else if (profile_type == "aac") {
        aac_count++
    } else {
        mp3_count++
    }
}

function finish_profile(required, token, tokens, command) {
    if (current_profile == "") {
        return
    }
    if (current_profile == "aac") {
        aac_count++
        required = target_section == "ts" ? "%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1" : "%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1"
    } else {
        mp3_count++
        required = target_section == "ts" ? "%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1" : "%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1"
    }
    command = profile_command
    gsub(/[[:space:]]+/, " ", command)
    sub(/^ /, "", command)
    sub(/ $/, "", command)
    if (command ~ /^'.*'$/ || command ~ /^".*"$/) {
        command = substr(command, 2, length(command) - 2)
    }
    if (command != required) {
        print "recorded-audio-profile: unknown or conflicting command for reserved profile in " target_section ".mp4" > "/dev/stderr"
        invalid = 1
    }
    if (current_profile == "aac" && aac_count > 1) {
        print "recorded-audio-profile: duplicate Home Assistant Audio in " target_section ".mp4" > "/dev/stderr"
        invalid = 1
    }
    if (current_profile == "mp3" && mp3_count > 1) {
        print "recorded-audio-profile: duplicate Home Assistant Audio MP3 in " target_section ".mp4" > "/dev/stderr"
        invalid = 1
    }
    current_profile = ""
    profile_text = ""
    profile_command = ""
    collect_command = 0
}

function flush_target() {
    if (target_section == "") {
        return
    }
    finish_profile()
    if (validate_only) {
        if (aac_count != 1) {
            print "recorded-audio-profile: " target_section ".mp4 must contain exactly one valid Home Assistant Audio profile" > "/dev/stderr"
            invalid = 1
        }
        if (mp3_count != 1) {
            print "recorded-audio-profile: " target_section ".mp4 must contain exactly one valid Home Assistant Audio MP3 profile" > "/dev/stderr"
            invalid = 1
        }
    } else {
        if (aac_count == 0) {
            add_profile(target_section == "ts" ? ts_profile_file : encoded_profile_file, "aac")
        }
        if (mp3_count == 0) {
            add_profile(target_section == "ts" ? ts_mp3_profile_file : encoded_mp3_profile_file, "mp3")
        }
    }
    target_section = ""
    aac_count = 0
    mp3_count = 0
}

/^stream:$/ {
    in_stream = 1
}
in_stream && /^[^[:space:]][^:]*:/ && $0 !~ /^stream:$/ {
    flush_target()
    in_stream = 0
    in_recorded = 0
    section = ""
    target_section = ""
}
in_stream && /^    recorded:$/ {
    in_recorded = 1
}
in_recorded && /^        (ts|encoded):$/ {
    flush_target()
    section = $1
    sub(/:$/, "", section)
}
in_recorded && /^        [^[:space:]][^:]*:/ && $0 !~ /^        (ts|encoded):$/ {
    flush_target()
    section = ""
    target_section = ""
}
section != "" && /^            mp4:$/ {
    flush_target()
    target_section = section
    aac_count = 0
    mp3_count = 0
    if (section == "ts") {
        ts_mp4_count++
    } else if (section == "encoded") {
        encoded_mp4_count++
    }
}
target_section != "" && /^                - name:/ {
    finish_profile()
    if ($0 ~ /^                - name:[[:space:]]*Home Assistant Audio MP3([[:space:]]+#.*)?[[:space:]]*$/ ||
        $0 ~ /^                - name:[[:space:]]*'Home Assistant Audio MP3'([[:space:]]+#.*)?[[:space:]]*$/ ||
        $0 ~ /^                - name:[[:space:]]*"Home Assistant Audio MP3"([[:space:]]+#.*)?[[:space:]]*$/) {
        current_profile = "mp3"
    } else if ($0 ~ /^                - name:[[:space:]]*Home Assistant Audio([[:space:]]+#.*)?[[:space:]]*$/ ||
        $0 ~ /^                - name:[[:space:]]*'Home Assistant Audio'([[:space:]]+#.*)?[[:space:]]*$/ ||
        $0 ~ /^                - name:[[:space:]]*"Home Assistant Audio"([[:space:]]+#.*)?[[:space:]]*$/) {
        current_profile = "aac"
    }
    if (current_profile != "") {
        profile_text = $0
        profile_command = ""
        collect_command = 0
    }
}
target_section != "" && current_profile != "" && $0 !~ /^            [^[:space:]][^:]*:/ {
    profile_text = profile_text " " $0
    if ($0 ~ /^[[:space:]]*cmd:/) {
        profile_command = $0
        sub(/^[[:space:]]*cmd:[[:space:]]*/, "", profile_command)
        if (profile_command == ">-" || profile_command == "|" || profile_command == ">") {
            profile_command = ""
            collect_command = 1
        } else {
            collect_command = 0
        }
    } else if (collect_command) {
        profile_command = profile_command " " $0
    }
}
target_section != "" && /^            [^[:space:]][^:]*:/ && $0 !~ /^            mp4:/ {
    flush_target()
}
{
    print
}
END {
    flush_target()
    if (ts_mp4_count != 1) {
        print "recorded-audio-profile: stream.recorded.ts.mp4 is missing or duplicated" > "/dev/stderr"
        invalid = 1
    }
    if (encoded_mp4_count != 1) {
        print "recorded-audio-profile: stream.recorded.encoded.mp4 is missing or duplicated" > "/dev/stderr"
        invalid = 1
    }
    if (invalid) {
        exit 1
    }
}
