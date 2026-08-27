#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/TravelCompanion.xcodeproj"
PROJECT_YML="$REPO_ROOT/project.yml"
PBXPROJ="$PROJECT_FILE/project.pbxproj"
EXPORT_OPTIONS="$REPO_ROOT/build/ExportOptions.plist"
PROJECT_YML_REL="project.yml"
PBXPROJ_REL="TravelCompanion.xcodeproj/project.pbxproj"

SCHEME="${SCHEME:-TravelCompanion}"
CONFIGURATION="${CONFIGURATION:-Release}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
ASC_APP_ID="${ASC_APP_ID:-6796555795}"
ASC_GROUP_NAME="${ASC_GROUP_NAME:-Internal Testers}"
ASC_KEY_ID="${ASC_KEY_ID:-7D3YAT286X}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-bb0c9a32-bd23-405d-9e9b-4eb0703dc5ea}"
ASC_TIMEOUT_SECONDS="${ASC_TIMEOUT_SECONDS:-600}"

TARGET_VERSION=""
TARGET_BUILD=""
SKIP_TESTS=0
ORIGINAL_ARG_COUNT=$#
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
Usage: scripts/release_testflight.sh [options]

Options:
  --version VERSION   Marketing version. Defaults to the current version.
  --build NUMBER      Build number. Defaults to current build + 1.
  --skip-tests        Skip the focused Agent session tests.
  -h, --help          Show this help.

Environment overrides:
  SIMULATOR_NAME, ASC_APP_ID, ASC_GROUP_NAME, ASC_KEY_ID, ASC_ISSUER_ID,
  ASC_TIMEOUT_SECONDS, SCHEME, CONFIGURATION.

The current branch is fast-forwarded from its configured upstream before
the version is updated. The release version commit is pushed before testing
and packaging, so a completed or interrupted run leaves the tree clean.
EOF
}

while (($#)); do
    case "$1" in
        --version)
            TARGET_VERSION="${2:?Missing value for --version}"
            shift 2
            ;;
        --build)
            TARGET_BUILD="${2:?Missing value for --build}"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$REPO_ROOT"

dirty_status="$(git status --porcelain --untracked-files=all)"
if [[ -n "$dirty_status" ]]; then
    recoverable_version_state=1
    while IFS= read -r status_line; do
        case "$status_line" in
            " M $PROJECT_YML_REL"|" M $PBXPROJ_REL") ;;
            *) recoverable_version_state=0 ;;
        esac
    done <<< "$dirty_status"

    unexpected_version_diff="$(
        git diff --unified=0 -- "$PROJECT_YML_REL" "$PBXPROJ_REL" |
            awk '
                /^(---|\+\+\+|@@)/ { next }
                /^[+-]/ {
                    if ($0 !~ /^[+-][[:space:]]*(MARKETING_VERSION:|CURRENT_PROJECT_VERSION:|MARKETING_VERSION =|CURRENT_PROJECT_VERSION =)/) {
                        print
                    }
                }
            '
    )"
    if [[ -n "$unexpected_version_diff" ]]; then
        recoverable_version_state=0
    fi

    if ((recoverable_version_state == 1)); then
        echo "Recovering version files left by an interrupted release"
        git restore --worktree -- "$PROJECT_YML_REL" "$PBXPROJ_REL"
    else
        echo "Working tree contains non-release changes; refusing to overwrite them." >&2
        echo "$dirty_status" >&2
        exit 1
    fi
fi

current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ -z "$current_branch" ]]; then
    echo "A release must be run from a branch, not a detached HEAD." >&2
    exit 1
fi

upstream_branch="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [[ -z "$upstream_branch" ]]; then
    echo "Branch $current_branch has no configured upstream; refusing to release unsynchronized code." >&2
    exit 1
fi

if [[ "${TRAVEL_COMPANION_RELEASE_REEXECUTED:-0}" != "1" ]]; then
    before_sync_sha="$(git rev-parse HEAD)"
    echo "Syncing $current_branch from $upstream_branch"
    git pull --ff-only
    after_sync_sha="$(git rev-parse HEAD)"

    if [[ "$before_sync_sha" != "$after_sync_sha" ]]; then
        echo "Remote updates applied; restarting the release with the synchronized script."
        if ((ORIGINAL_ARG_COUNT > 0)); then
            TRAVEL_COMPANION_RELEASE_REEXECUTED=1 \
                exec "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "${ORIGINAL_ARGS[@]}"
        else
            TRAVEL_COMPANION_RELEASE_REEXECUTED=1 \
                exec "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
        fi
    fi
fi
unset TRAVEL_COMPANION_RELEASE_REEXECUTED

for required_command in git awk basename xcodebuild codesign xcrun ruby tee; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Missing required command: $required_command" >&2
        exit 1
    fi
done
for required_tool in /usr/bin/grep /usr/bin/sed /usr/libexec/PlistBuddy; do
    if [[ ! -x "$required_tool" ]]; then
        echo "Missing required tool: $required_tool" >&2
        exit 1
    fi
done
if ! xcrun --find altool >/dev/null 2>&1; then
    echo "Could not find altool in the selected Xcode installation." >&2
    exit 1
fi

current_version="$(awk '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
current_build="$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")"

if [[ -z "$current_version" || ! "$current_build" =~ ^[0-9]+$ ]]; then
    echo "Could not read the current version/build from project.yml." >&2
    exit 1
fi

TARGET_VERSION="${TARGET_VERSION:-$current_version}"
TARGET_BUILD="${TARGET_BUILD:-$((current_build + 1))}"

if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid marketing version: $TARGET_VERSION" >&2
    exit 1
fi
if [[ ! "$TARGET_BUILD" =~ ^[0-9]+$ ]]; then
    echo "Invalid build number: $TARGET_BUILD" >&2
    exit 1
fi
if ((TARGET_BUILD <= current_build)); then
    echo "Build number must increase: current=$current_build target=$TARGET_BUILD" >&2
    exit 1
fi

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    echo "Missing export options: $EXPORT_OPTIONS" >&2
    exit 1
fi

key_file=""
for candidate in \
    "${ASC_PRIVATE_KEYS_DIR:-}/AuthKey_${ASC_KEY_ID}.p8" \
    "$HOME/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
    "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"; do
    if [[ -f "$candidate" ]]; then
        key_file="$candidate"
        break
    fi
done
if [[ -z "$key_file" ]]; then
    echo "Could not find AuthKey_${ASC_KEY_ID}.p8 in a supported private-key directory." >&2
    exit 1
fi

release_name="${TARGET_VERSION}-${TARGET_BUILD}"
archive_path="$REPO_ROOT/build/TravelCompanion-${release_name}.xcarchive"
export_path="$REPO_ROOT/build/export-${release_name}"
test_log="$REPO_ROOT/build/test-${release_name}.log"
archive_log="$REPO_ROOT/build/archive-${release_name}.log"
export_log="$REPO_ROOT/build/export-${release_name}.log"
upload_log="$REPO_ROOT/build/altool-upload-${release_name}.log"
asc_log="$REPO_ROOT/build/asc-processing-${release_name}.log"

if [[ -e "$archive_path" || -e "$export_path" ]]; then
    echo "Release output already exists for $release_name; refusing to overwrite it." >&2
    exit 1
fi

echo "Preparing TravelCompanion $TARGET_VERSION ($TARGET_BUILD)"

/usr/bin/sed -E -i '' \
    "s/^([[:space:]]*MARKETING_VERSION:).*/\\1 $TARGET_VERSION/" \
    "$PROJECT_YML"
/usr/bin/sed -E -i '' \
    "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\\1 $TARGET_BUILD/" \
    "$PROJECT_YML"
/usr/bin/sed -E -i '' \
    "s/(MARKETING_VERSION = )[^;]+;/\\1$TARGET_VERSION;/g" \
    "$PBXPROJ"
/usr/bin/sed -E -i '' \
    "s/(CURRENT_PROJECT_VERSION = )[^;]+;/\\1$TARGET_BUILD;/g" \
    "$PBXPROJ"

if ! /usr/bin/grep -Fq "MARKETING_VERSION: $TARGET_VERSION" "$PROJECT_YML" || \
   ! /usr/bin/grep -Fq "CURRENT_PROJECT_VERSION: $TARGET_BUILD" "$PROJECT_YML"; then
    echo "Version update verification failed for project.yml." >&2
    exit 1
fi
if [[ "$(/usr/bin/grep -Fc "MARKETING_VERSION = $TARGET_VERSION;" "$PBXPROJ")" -ne 2 ]] || \
   [[ "$(/usr/bin/grep -Fc "CURRENT_PROJECT_VERSION = $TARGET_BUILD;" "$PBXPROJ")" -ne 2 ]]; then
    echo "Version update verification failed for project.pbxproj." >&2
    exit 1
fi

git diff --check

echo "Committing and pushing release version $TARGET_VERSION ($TARGET_BUILD)"
git add -- "$PROJECT_YML_REL" "$PBXPROJ_REL"
git commit -m "chore: release $TARGET_VERSION ($TARGET_BUILD)"
if ! git push; then
    echo "Remote changed while preparing the release; rebasing the version commit."
    if ! git pull --rebase; then
        git rebase --abort || true
        echo "Could not rebase the release version commit; release stopped before packaging." >&2
        exit 1
    fi
    git push
fi

if ((SKIP_TESTS == 0)); then
    echo "Running AgentV2SessionStoreTests on $SIMULATOR_NAME"
    xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
        -only-testing:TravelCompanionTests/AgentV2SessionStoreTests \
        2>&1 | tee "$test_log"
fi

echo "Archiving $release_name"
xcodebuild archive \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$archive_path" \
    -destination "generic/platform=iOS" \
    -allowProvisioningUpdates \
    2>&1 | tee "$archive_log"

app_path="$archive_path/Products/Applications/TravelCompanion.app"
extension_path="$app_path/PlugIns/TravelCompanionShareExtension.appex"

assert_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Unexpected $key in $plist: expected=$expected actual=$actual" >&2
        exit 1
    fi
}

assert_plist_value "$app_path/Info.plist" CFBundleShortVersionString "$TARGET_VERSION"
assert_plist_value "$app_path/Info.plist" CFBundleVersion "$TARGET_BUILD"
assert_plist_value "$app_path/Info.plist" ITSAppUsesNonExemptEncryption false
assert_plist_value "$extension_path/Info.plist" CFBundleShortVersionString "$TARGET_VERSION"
assert_plist_value "$extension_path/Info.plist" CFBundleVersion "$TARGET_BUILD"
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Exporting IPA"
xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    2>&1 | tee "$export_log"

ipa_path="$export_path/TravelCompanion.ipa"
if [[ ! -f "$ipa_path" ]]; then
    echo "IPA was not exported to $ipa_path" >&2
    exit 1
fi

echo "Uploading IPA to App Store Connect"
xcrun altool \
    --upload-app \
    --type ios \
    --file "$ipa_path" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee "$upload_log"

echo "Waiting for App Store Connect processing and $ASC_GROUP_NAME assignment"
ASC_KEY_FILE="$key_file" \
ASC_KEY_ID="$ASC_KEY_ID" \
ASC_ISSUER_ID="$ASC_ISSUER_ID" \
ASC_APP_ID="$ASC_APP_ID" \
ASC_BUILD_NUMBER="$TARGET_BUILD" \
ASC_GROUP_NAME="$ASC_GROUP_NAME" \
ASC_TIMEOUT_SECONDS="$ASC_TIMEOUT_SECONDS" \
ruby -rjson -ropenssl -rbase64 -rnet/http -ruri <<'RUBY' 2>&1 | tee "$asc_log"
issuer = ENV.fetch("ASC_ISSUER_ID")
key_id = ENV.fetch("ASC_KEY_ID")
app_id = ENV.fetch("ASC_APP_ID")
build_number = ENV.fetch("ASC_BUILD_NUMBER")
group_name = ENV.fetch("ASC_GROUP_NAME")
timeout = Integer(ENV.fetch("ASC_TIMEOUT_SECONDS"))
key = OpenSSL::PKey::EC.new(File.read(ENV.fetch("ASC_KEY_FILE")))

base64url = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
header = base64url.call({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
payload = base64url.call({
  iss: issuer,
  iat: Time.now.to_i - 30,
  exp: Time.now.to_i + 1_200,
  aud: "appstoreconnect-v1"
}.to_json)
signing_input = "#{header}.#{payload}"
der_signature = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
sequence = OpenSSL::ASN1.decode(der_signature)
raw_signature = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
token = "#{signing_input}.#{base64url.call(raw_signature)}"

request = lambda do |method, path, params = nil, body = nil|
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  uri.query = URI.encode_www_form(params) if params
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
  http_request = request_class.new(uri)
  http_request["Authorization"] = "Bearer #{token}"
  http_request["Content-Type"] = "application/json"
  http_request.body = body.to_json if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(http_request) }
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  [response.code.to_i, parsed]
end

group_added = false
started_at = Time.now

loop do
  code, json = request.call(:get, "/v1/builds", {
    "filter[app]" => app_id,
    "filter[version]" => build_number,
    "limit" => 10
  })
  abort("ASC builds query failed HTTP #{code}: #{json.dig("errors", 0, "detail")}") unless code == 200

  build = json.fetch("data", []).first
  if build.nil?
    puts "#{Time.now.strftime("%H:%M:%S")} build #{build_number}: waiting for ingestion"
  else
    build_id = build.fetch("id")
    processing_state = build.dig("attributes", "processingState")
    beta_code, beta_json = request.call(:get, "/v1/buildBetaDetails", {
      "filter[build]" => build_id,
      "limit" => 1
    })
    internal_state = beta_code == 200 ? beta_json.dig("data", 0, "attributes", "internalBuildState") : nil
    suffix = internal_state ? " / #{internal_state}" : ""
    puts "#{Time.now.strftime("%H:%M:%S")} build #{build_number}: #{processing_state}#{suffix}"

    abort("App Store Connect processing failed") if processing_state == "FAILED"

    if processing_state == "VALID" && !group_added
      group_code, group_json = request.call(:get, "/v1/betaGroups", {
        "filter[app]" => app_id,
        "filter[name]" => group_name,
        "limit" => 10
      })
      abort("ASC betaGroups query failed HTTP #{group_code}") unless group_code == 200
      group = group_json.fetch("data", []).find { |candidate| candidate.dig("attributes", "name") == group_name }
      abort("Beta group not found: #{group_name}") unless group

      relation_code, relation_json = request.call(
        :post,
        "/v1/betaGroups/#{group.fetch("id")}/relationships/builds",
        nil,
        { data: [{ type: "builds", id: build_id }] }
      )
      unless [204, 409].include?(relation_code)
        abort("Adding build to beta group failed HTTP #{relation_code}: #{relation_json.dig("errors", 0, "detail")}")
      end
      group_added = true
      puts "#{Time.now.strftime("%H:%M:%S")} added to #{group_name}"
    end

    if group_added && internal_state == "READY_FOR_BETA_TESTING"
      puts "ASC_READY build_id=#{build_id} processing=#{processing_state} internal=#{internal_state} group=#{group_name}"
      break
    end
  end

  STDOUT.flush
  abort("Timed out waiting for App Store Connect") if Time.now - started_at > timeout
  sleep 15
end
RUBY

echo
echo "TestFlight release complete: $TARGET_VERSION ($TARGET_BUILD)"
echo "Archive: $archive_path"
echo "IPA: $ipa_path"
echo "Upload log: $upload_log"
echo "ASC log: $asc_log"
