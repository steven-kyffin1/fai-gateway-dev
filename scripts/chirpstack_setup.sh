#!/bin/bash
# FAI Gateway - ChirpStack Auto-Provisioning Script (v4 Native gRPC)

echo "--- 🤖 Booting ChirpStack Ghost Admin (gRPC Edition) ---"

# Resolve project paths independently of the current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

cd "$PROJECT_ROOT" || {
    echo "ERROR: Could not enter project directory: $PROJECT_ROOT"
    exit 1
}

# Load gateway configuration before any conditional provisioning
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: Environment file not found: $ENV_FILE"
    exit 1
fi

echo "Gateway serial: ${GATEWAY_SERIAL:-not-set}"
echo "LoRaWAN water meters: ${LORAWAN_WATER_METERS:-false}"

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

# ==========================================
# 5. Find, create or update RAK device profile
# ==========================================

RAK_PROFILE_NAME="RAK3272 Node"

echo "Provisioning Device Profile: $RAK_PROFILE_NAME..."

RAK_PROFILE_LIST=$(grpcurl \
    -plaintext \
    -H "authorization: Bearer $TOKEN" \
    -d "{
        \"limit\": 100,
        \"tenantId\": \"$TENANT_ID\",
        \"search\": \"$RAK_PROFILE_NAME\"
    }" \
    localhost:8080 \
    api.DeviceProfileService/List 2>&1)

RAK_PROFILE_ID=$(echo "$RAK_PROFILE_LIST" |
    jq -r \
        --arg NAME "$RAK_PROFILE_NAME" \
        '.result[]? | select(.name == $NAME) | .id' |
    head -n 1)

if [ -z "$RAK_PROFILE_ID" ]; then
    echo "Creating Device Profile: $RAK_PROFILE_NAME..."

    RAK_PROFILE_RESP=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "{
            \"deviceProfile\": {
                \"tenantId\": \"$TENANT_ID\",
                \"name\": \"$RAK_PROFILE_NAME\",
                \"description\": \"FAI ShedSensor RAK3272 LoRaWAN node\",
                \"region\": \"EU868\",
                \"macVersion\": \"LORAWAN_1_0_3\",
                \"regParamsRevision\": \"RP002_1_0_3\",
                \"supportsOtaa\": true,
                \"supportsClassB\": false,
                \"supportsClassC\": false,
                \"adrAlgorithmId\": \"default\",
                \"tags\": {
                    \"sensor_type\": \"shed_sensor\",
                    \"manufacturer\": \"RAKwireless\",
                    \"model\": \"RAK3272\",
                    \"transport\": \"lorawan\"
                }
            }
        }" \
        localhost:8080 \
        api.DeviceProfileService/Create 2>&1)

    RAK_PROFILE_ID=$(echo "$RAK_PROFILE_RESP" |
        jq -r '.id // empty')

    if [ -z "$RAK_PROFILE_ID" ]; then
        echo "ERROR: Could not create RAK device profile."
        echo "$RAK_PROFILE_RESP"
        exit 1
    fi

    echo "✅ RAK device profile created: $RAK_PROFILE_ID"
else
    echo "RAK profile exists: $RAK_PROFILE_ID"
    echo "Ensuring profile tags are present..."

    RAK_PROFILE_GET=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "{
            \"id\": \"$RAK_PROFILE_ID\"
        }" \
        localhost:8080 \
        api.DeviceProfileService/Get 2>&1)

    RAK_PROFILE_OBJECT=$(echo "$RAK_PROFILE_GET" |
        jq '
            .deviceProfile
            | .description =
                "FAI ShedSensor RAK3272 LoRaWAN node"
            | .tags = (
                (.tags // {}) +
                {
                    "sensor_type": "shed_sensor",
                    "manufacturer": "RAKwireless",
                    "model": "RAK3272",
                    "transport": "lorawan"
                }
            )
        ')

    if [ -z "$RAK_PROFILE_OBJECT" ] ||
       [ "$RAK_PROFILE_OBJECT" = "null" ]; then
        echo "ERROR: Could not retrieve RAK device profile."
        echo "$RAK_PROFILE_GET"
        exit 1
    fi

    RAK_UPDATE_PAYLOAD=$(jq -n \
        --argjson PROFILE "$RAK_PROFILE_OBJECT" \
        '{
            deviceProfile: $PROFILE
        }')

    RAK_UPDATE_RESP=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "$RAK_UPDATE_PAYLOAD" \
        localhost:8080 \
        api.DeviceProfileService/Update 2>&1)

    if [ "$RAK_UPDATE_RESP" = "{}" ]; then
        echo "✅ RAK device profile updated."
    else
        echo "ERROR: Could not update RAK device profile."
        echo "$RAK_UPDATE_RESP"
        exit 1
    fi
fi

# ==========================================
# 6. Find or create Hen House application
# ==========================================

HEN_APP_NAME="Hen House Sensors"

echo "Provisioning Application: $HEN_APP_NAME..."

HEN_APP_LIST=$(grpcurl \
    -plaintext \
    -H "authorization: Bearer $TOKEN" \
    -d "{
        \"limit\": 100,
        \"tenantId\": \"$TENANT_ID\",
        \"search\": \"$HEN_APP_NAME\"
    }" \
    localhost:8080 \
    api.ApplicationService/List 2>&1)

HEN_APP_ID=$(echo "$HEN_APP_LIST" |
    jq -r \
        --arg NAME "$HEN_APP_NAME" \
        '.result[]? | select(.name == $NAME) | .id' |
    head -n 1)

if [ -n "$HEN_APP_ID" ]; then
    echo "ℹ️  Application already exists: $HEN_APP_NAME"
    echo "Hen House application ID: $HEN_APP_ID"
else
    HEN_APP_RESP=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "{
            \"application\": {
                \"tenantId\": \"$TENANT_ID\",
                \"name\": \"$HEN_APP_NAME\",
                \"description\": \"Auto-Provisioned by FAI Bootstrap\",
                \"tags\": {
                    \"sensor_type\": \"shed_sensor\",
                    \"transport\": \"lorawan\"
                }
            }
        }" \
        localhost:8080 \
        api.ApplicationService/Create 2>&1)

    HEN_APP_ID=$(echo "$HEN_APP_RESP" |
        jq -r '.id // empty')

    if [ -n "$HEN_APP_ID" ]; then
        echo "✅ Hen House application created: $HEN_APP_ID"
    else
        echo "ERROR: Could not create Hen House application."
        echo "$HEN_APP_RESP"
        exit 1
    fi
fi

echo ""

if [ "${LORAWAN_WATER_METERS:-false}" = "true" ]; then
    echo ""
    echo "--- Provisioning LoRaWAN water-meter support ---"

    WATER_PROFILE_NAME="B METERS HYDRODIGIT-S1 EU868"
    WATER_APP_NAME="Water Meters"

    # ------------------------------------------------------------
    # Find or create the device profile
    # ------------------------------------------------------------

    WATER_PROFILE_LIST=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "{
            \"limit\": 100,
            \"tenantId\": \"$TENANT_ID\",
            \"search\": \"$WATER_PROFILE_NAME\"
        }" \
        localhost:8080 \
        api.DeviceProfileService/List 2>&1)

    WATER_PROFILE_ID=$(echo "$WATER_PROFILE_LIST" |
        jq -r \
            --arg NAME "$WATER_PROFILE_NAME" \
            '.result[]? | select(.name == $NAME) | .id' |
        head -n 1)

    if [ -n "$WATER_PROFILE_ID" ]; then
        echo "ℹ️  Device profile already exists: $WATER_PROFILE_NAME"
    else
        WATER_PROFILE_RESP=$(grpcurl \
            -plaintext \
            -H "authorization: Bearer $TOKEN" \
            -d "{
                \"deviceProfile\": {
                    \"tenantId\": \"$TENANT_ID\",
                    \"name\": \"$WATER_PROFILE_NAME\",
                    \"description\": \"B METERS HYDRODIGIT-S1 LoRaWAN water meter\",
                    \"region\": \"EU868\",
                    \"macVersion\": \"LORAWAN_1_0_3\",
                    \"regParamsRevision\": \"RP002_1_0_3\",
                    \"supportsOtaa\": true,
                    \"supportsClassB\": false,
                    \"supportsClassC\": false,
                    \"adrAlgorithmId\": \"default\",
                    \"tags\": {
                        \"sensor_type\": \"water_meter\",
                        \"manufacturer\": \"B_METERS\",
                        \"model\": \"HYDRODIGIT_S1\"
                    }
                }
            }" \
            localhost:8080 \
            api.DeviceProfileService/Create 2>&1)

        WATER_PROFILE_ID=$(echo "$WATER_PROFILE_RESP" |
            jq -r '.id // empty')

        if [ -n "$WATER_PROFILE_ID" ]; then
            echo "✅ Water-meter device profile created."
        else
            echo "ERROR: Could not create water-meter device profile."
            echo "$WATER_PROFILE_RESP"
            exit 1
        fi
    fi

    # ------------------------------------------------------------
    # Find or create the application
    # ------------------------------------------------------------

    WATER_APP_LIST=$(grpcurl \
        -plaintext \
        -H "authorization: Bearer $TOKEN" \
        -d "{
            \"limit\": 100,
            \"tenantId\": \"$TENANT_ID\",
            \"search\": \"$WATER_APP_NAME\"
        }" \
        localhost:8080 \
        api.ApplicationService/List 2>&1)

    WATER_APP_ID=$(echo "$WATER_APP_LIST" |
        jq -r \
            --arg NAME "$WATER_APP_NAME" \
            '.result[]? | select(.name == $NAME) | .id' |
        head -n 1)

    if [ -n "$WATER_APP_ID" ]; then
        echo "ℹ️  Application already exists: $WATER_APP_NAME"
    else
        WATER_APP_RESP=$(grpcurl \
            -plaintext \
            -H "authorization: Bearer $TOKEN" \
            -d "{
                \"application\": {
                    \"tenantId\": \"$TENANT_ID\",
                    \"name\": \"$WATER_APP_NAME\",
                    \"description\": \"FAI LoRaWAN water meters\",
                    \"tags\": {
                        \"sensor_type\": \"water_meter\",
                        \"transport\": \"lorawan\"
                    }
                }
            }" \
            localhost:8080 \
            api.ApplicationService/Create 2>&1)

        WATER_APP_ID=$(echo "$WATER_APP_RESP" |
            jq -r '.id // empty')

        if [ -n "$WATER_APP_ID" ]; then
            echo "✅ Water Meters application created."
        else
            echo "ERROR: Could not create Water Meters application."
            echo "$WATER_APP_RESP"
            exit 1
        fi
    fi

    echo "Water application ID: $WATER_APP_ID"
    echo "Water profile ID: $WATER_PROFILE_ID"
fi

# ==========================================
# 7. Auto-Register the Gateway
# ==========================================
echo "Registering Gateway in ChirpStack..."

# Source the .env file to get GATEWAY_SERIAL
if [ -z "${GATEWAY_SERIAL:-}" ]; then
    echo "ERROR: GATEWAY_SERIAL is not defined."
    exit 1
fi

GW_NAME="${GATEWAY_HOSTNAME:-$GATEWAY_SERIAL}"

GW_RESP=$(grpcurl -plaintext -H "authorization: Bearer $TOKEN" -d "{
    \"gateway\": {
        \"tenantId\": \"$TENANT_ID\",
        \"gatewayId\": \"$GATEWAY_SERIAL\",
        \"name\": \"$GW_NAME\",
        \"description\": \"Auto-Provisioned Zero-Touch Gateway\",
        \"downlinkPriority\": 1
    }
}" localhost:8080 api.GatewayService/Create 2>&1)

if [ "$GW_RESP" = "{}" ] || echo "$GW_RESP" | grep -q '"id"'; then
    echo "✅ Gateway Registered Successfully!"
elif echo "$GW_RESP" | grep -qi "already exists\|duplicate"; then
    echo "ℹ️  Gateway already exists, skipping."
else
    echo "⚠️  Unexpected response: $GW_RESP"
fi

echo "--- 🎉 Auto-Provisioning Complete ---"
