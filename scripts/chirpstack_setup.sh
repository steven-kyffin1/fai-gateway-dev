#!/bin/bash
# FAI Gateway - ChirpStack Auto-Provisioning Script (v4 Native gRPC)

echo "--- 🤖 Booting ChirpStack Ghost Admin (gRPC Edition) ---"

# 1. Install jq if missing
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    sudo apt-get install -y -q jq
fi

# 2. Install grpcurl for ARM64
if ! command -v grpcurl &> /dev/null; then
    echo "Installing grpcurl for ARM64..."
    wget -qO /tmp/grpcurl.tar.gz "https://github.com/fullstorydev/grpcurl/releases/download/v1.8.9/grpcurl_1.8.9_linux_arm64.tar.gz"
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to download grpcurl."
        exit 1
    fi
    
    tar -xzf /tmp/grpcurl.tar.gz -C /tmp grpcurl
    chmod +x /tmp/grpcurl
    sudo mv /tmp/grpcurl /usr/local/bin/grpcurl
    rm -f /tmp/grpcurl.tar.gz
fi

# 3. Authenticate directly via gRPC on port 8080
echo "Logging into ChirpStack gRPC API (port 8080)..."
LOGIN_RESP=$(grpcurl -plaintext -d '{"email": "admin", "password": "admin"}' localhost:8080 api.InternalService/Login 2>&1)
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.jwt // empty' 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Authentication failed. Raw response:"
    echo "$LOGIN_RESP"
    echo "Run 'docker compose logs --tail=20 chirpstack' to check status."
    exit 1
fi
echo "✅ Authenticated!"

# 4. Get tenant ID
TENANT_RESP=$(grpcurl -plaintext -H "authorization: Bearer $TOKEN" -d '{"limit": 10}' localhost:8080 api.TenantService/List 2>&1)
TENANT_ID=$(echo "$TENANT_RESP" | jq -r '.result[0].id // empty' 2>/dev/null)

if [ -z "$TENANT_ID" ]; then
    echo "ERROR: Could not retrieve Tenant ID."
    echo "$TENANT_RESP"
    exit 1
fi
echo "Tenant ID: $TENANT_ID"

# 5. Create Device Profile
echo "Creating Device Profile: RAK3272 Node..."
PROFILE_RESP=$(grpcurl -plaintext -H "authorization: Bearer $TOKEN" -d "{
    \"deviceProfile\": {
        \"tenantId\": \"$TENANT_ID\",
        \"name\": \"RAK3272 Node\",
        \"region\": \"EU868\",
        \"macVersion\": \"LORAWAN_1_0_3\",
        \"regParamsRevision\": \"RP002_1_0_3\",
        \"supportsOtaa\": true,
        \"adrAlgorithmId\": \"default\"
    }
}" localhost:8080 api.DeviceProfileService/Create 2>&1)

if echo "$PROFILE_RESP" | grep -q '"id"'; then
    echo "✅ Device Profile created!"
elif echo "$PROFILE_RESP" | grep -qi "already exists\|duplicate"; then
    echo "ℹ️  Device Profile already exists, skipping."
else
    echo "⚠️  Unexpected response: $PROFILE_RESP"
fi

# 6. Create Application
echo "Creating Application: Hen House Sensors..."
APP_RESP=$(grpcurl -plaintext -H "authorization: Bearer $TOKEN" -d "{
    \"application\": {
        \"tenantId\": \"$TENANT_ID\",
        \"name\": \"Hen House Sensors\",
        \"description\": \"Auto-Provisioned by FAI Bootstrap\"
    }
}" localhost:8080 api.ApplicationService/Create 2>&1)

if echo "$APP_RESP" | grep -q '"id"'; then
    echo "✅ Application created!"
elif echo "$APP_RESP" | grep -qi "already exists\|duplicate"; then
    echo "ℹ️  Application already exists, skipping."
else
    echo "⚠️  Unexpected response: $APP_RESP"
fi

echo ""
echo "--- 🎉 Auto-Provisioning Complete ---"