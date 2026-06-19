#!/bin/bash
# FAI Gateway - ChirpStack Auto-Provisioning Script
# This automates Phase 1 (Device Profile) and Phase 2 (Application)

echo "--- 🤖 Booting ChirpStack Ghost Admin ---"

# 1. Install jq if it's missing
if ! command -v jq &> /dev/null; then
    echo "Installing jq (JSON processor)..."
    sudo apt-get install -y jq
fi

# 2. Authenticate and get the JWT Token
echo "Logging into ChirpStack API..."
TOKEN=$(curl -s -X POST "http://localhost:8080/api/internal/login" \
  -H "Content-Type: application/json" \
  -d '{"email": "admin", "password": "admin"}' | jq -r .jwt)

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "ERROR: Could not log in. Is ChirpStack running?"
    exit 1
fi

# 3. Get the Default Tenant ID (Required to build anything in ChirpStack)
TENANT_ID=$(curl -s -X GET "http://localhost:8080/api/tenants?limit=10" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.result[0].id')

echo "Acquired Tenant ID: $TENANT_ID"

# 4. PHASE 1: Auto-Create the Device Profile
echo "Building Device Profile (RAK3272 Node)..."
PROFILE_RESP=$(curl -s -X POST "http://localhost:8080/api/device-profiles" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{
    \"deviceProfile\": {
      \"name\": \"RAK3272 Node Profile\",
      \"tenantId\": \"$TENANT_ID\",
      \"region\": \"EU868\",
      \"macVersion\": \"1.0.3\",
      \"regParamsRevision\": \"RP002-1.0.3\",
      \"supportsJoin\": true,
      \"supportsOtaa\": true
    }
  }")

# Extract the new Profile ID just in case we need it
PROFILE_ID=$(echo $PROFILE_RESP | jq -r '.id')
echo "✅ Profile Created! (ID: $PROFILE_ID)"

# 5. PHASE 2: Auto-Create the Application (The Folder)
echo "Building Application (Hen House Sensors)..."
curl -s -X POST "http://localhost:8080/api/applications" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{
    \"application\": {
      \"name\": \"Hen House Sensors\",
      \"description\": \"Auto-Provisioned by FAI Bootstrap\",
      \"tenantId\": \"$TENANT_ID\"
    }
  }" > /dev/null

echo "✅ Application Created!"
echo "--- 🎉 Auto-Provisioning Complete ---"