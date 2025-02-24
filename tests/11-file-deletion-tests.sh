#!/bin/bash
set -e

TESTCAFE_TESTS_FOLDER="$(pwd)/$(dirname $0)/$(basename $0 .sh)/testcafe"
use_env "DRUPAL_DEFAULT_MIGRATIONS_VALIDATE=false"

# Start the backend that serves the media files to be migrated
# Listens internally on port 80 (addressed as http://<assets_container>/assets/)
startMigrationAssetsContainer

# Execute migrations using testcafe
docker run --network gateway --env-file=$(pwd)/.env -v "${TESTCAFE_TESTS_FOLDER}":/tests testcafe/testcafe:"${TESTCAFE_VERSION}" --screenshots path=/tests/screenshots,takeOnFails=true chromium /tests/**/*.js
