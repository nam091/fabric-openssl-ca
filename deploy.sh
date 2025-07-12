#!/bin/bash

# =====================================================================
# == SMARTBANK FABRIC v2.0 - PHIÊN BẢN CÓ HỖ TRỢ THU HỒI QUYỀN (CRL) ==
# =====================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export FABRIC_CFG_PATH=${PWD}
export PATH=${PWD}/fabric-samples/bin:$PATH

COMPOSE_PROJECT_NAME="smartbank-fabric"
NETWORK_NAME="${COMPOSE_PROJECT_NAME}_smartbank_net"

PEER_SMARTBANKA_PORT=7051
PEER_SMARTBANKB_PORT=8051
ORDERER_PORT=7050

echo '================================================================================'
echo "SmartBank Fabric v2.0 - Sử dụng chứng chỉ OpenSSL có sẵn + Hỗ trợ CRL"
echo '================================================================================'

# === DỌN DẸP ===
cleanup() {
    echo "== DỌN DẸP =="
    docker-compose down -v --remove-orphans 2>/dev/null || true
    docker volume prune -f
    sudo rm -rf crypto-config config .env.msp
    echo "✅ Môi trường đã được dọn dẹp."
}

# === KIỂM TRA CHỨNG CHỈ CÓ SẴN ===
# Trong file deploy.sh

validate_certs() {
    echo "== KIỂM TRA CHỨNG CHỈ CÓ SẴN =="
    
    # SỬA LẠI ĐƯỜNG DẪN Ở ĐÂY (thêm /certs/)
    if [ ! -f "external-cas/smartbanka-rca/certs/ca.crt" ] || \
       [ ! -f "external-cas/smartbankb-rca/certs/ca.crt" ] || \
       [ ! -f "external-cas/orderer-rca/certs/ca.crt" ]; then
        echo "❌ Thiếu chứng chỉ OpenSSL trong external-cas/"
        exit 1
    fi
    
    # SỬA LẠI ĐƯỜNG DẪN Ở ĐÂY (thêm /certs/)
    SMARTBANKA_ORG=$(openssl x509 -in external-cas/smartbanka-rca/certs/ca.crt -noout -subject | sed -n 's/.*O=\([^,]*\).*/\1/p')
    SMARTBANKB_ORG=$(openssl x509 -in external-cas/smartbankb-rca/certs/ca.crt -noout -subject | sed -n 's/.*O=\([^,]*\).*/\1/p')
    ORDERER_ORG=$(openssl x509 -in external-cas/orderer-rca/certs/ca.crt -noout -subject | sed -n 's/.*O=\([^,]*\).*/\1/p')
    
    export SMARTBANKA_MSP_ID="${SMARTBANKA_ORG}MSP"
    export SMARTBANKB_MSP_ID="${SMARTBANKB_ORG}MSP"
    export ORDERER_MSP_ID="${ORDERER_ORG}MSP"
    
    echo "== Thông tin MSP từ chứng chỉ có sẵn: =="
    echo "== - SmartBankA: $SMARTBANKA_MSP_ID =="
    echo "== - SmartBankB: $SMARTBANKB_MSP_ID =="
    echo "== - Orderer: $ORDERER_MSP_ID =="
    
    # Lưu biến MSP vào file để các script khác có thể dùng
    cat > .env.msp << EOF
export SMARTBANKA_MSP_ID=$SMARTBANKA_MSP_ID
export SMARTBANKB_MSP_ID=$SMARTBANKB_MSP_ID
export ORDERER_MSP_ID=$ORDERER_MSP_ID
EOF
    
    mkdir -p config crypto-config
    echo "✅ Chứng chỉ OpenSSL đã được kiểm tra."
}

# === TẠO CHỨNG CHỈ ĐƠN GIẢN BẰNG OPENSSL (PHIÊN BẢN THỐNG NHẤT TÊN) ===
create_simple_certs() {
    local org_type=$1
    local org_name=$2
    
    echo "== Tạo chứng chỉ và CRL cho $org_name =="
    
    # --- 1. Khai báo biến và đường dẫn ---
    local ca_key="external-cas/${org_name}-rca/private/ca.key"
    local ca_crt="external-cas/${org_name}-rca/certs/ca.crt"
    local org_msp_name=$(openssl x509 -in "$ca_crt" -noout -subject | sed -n 's/.*O=\([^,]*\).*/\1/p')

    if [ "$org_type" = "orderer" ]; then
        local domain="example.com"
        local msp_dir="crypto-config/ordererOrganizations/${domain}"
        local node_name="orderer"
    else
        local domain="${org_name}.com"
        local msp_dir="crypto-config/peerOrganizations/${domain}"
        local node_name="peer0"
    fi
    
    local node_path="${msp_dir}/${org_type}s/${node_name}.${domain}"
    # Admin vẫn giữ nguyên viết hoa để nhất quán với các file khác
    local admin_path="${msp_dir}/users/Admin@${domain}"
    
    # --- 2. Tạo cấu trúc thư mục và các file cơ bản cho ORG MSP ---
    mkdir -p "${msp_dir}/msp/cacerts" "${msp_dir}/msp/admincerts" "${msp_dir}/msp/crls"
    cp "$ca_crt" "${msp_dir}/msp/cacerts/ca.crt"
    touch "${msp_dir}/msp/index.txt"
    echo 1000 > "${msp_dir}/msp/crlnumber"
    
    openssl ca -gencrl -keyfile "$ca_key" -cert "$ca_crt" -out "${msp_dir}/msp/crls/ca.crl" -config <(cat <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = ${msp_dir}/msp
database = \$dir/index.txt
crlnumber = \$dir/crlnumber
default_md = sha256
preserve = no
policy = policy_match
default_crl_days = 30
crl_extensions = crl_ext
[ policy_match ]
countryName = optional
stateOrProvinceName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied
[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF
)

    # --- 3. Tạo chứng chỉ cho NODE (Peer hoặc Orderer) ---
    echo "---> Tạo chứng chỉ cho Node: ${node_name}.${domain}"
    mkdir -p "${node_path}/msp/cacerts" "${node_path}/msp/keystore" "${node_path}/msp/signcerts" "${node_path}/msp/admincerts"
    openssl ecparam -name prime256v1 -genkey -noout -out "${node_path}/msp/keystore/priv_sk"
    openssl req -new -key "${node_path}/msp/keystore/priv_sk" -out "${node_path}/msp/cert.csr" -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${org_msp_name}/OU=${org_type}/CN=${node_name}.${domain}"
    openssl x509 -req -in "${node_path}/msp/cert.csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial -out "${node_path}/msp/signcerts/cert.pem" -days 365 -sha256
    cp "$ca_crt" "${node_path}/msp/cacerts/ca.crt"
    rm "${node_path}/msp/cert.csr"

    # --- 4. Tạo chứng chỉ cho ADMIN ---
    echo "---> Tạo chứng chỉ cho Admin: Admin@${domain}"
    mkdir -p "${admin_path}/msp/cacerts" "${admin_path}/msp/keystore" "${admin_path}/msp/signcerts"
    openssl ecparam -name prime256v1 -genkey -noout -out "${admin_path}/msp/keystore/priv_sk"
    openssl req -new -key "${admin_path}/msp/keystore/priv_sk" -out "${admin_path}/msp/cert.csr" -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${org_msp_name}/OU=admin/CN=Admin@${domain}"
    openssl x509 -req -in "${admin_path}/msp/cert.csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial -out "${admin_path}/msp/signcerts/cert.pem" -days 365 -sha256
    cp "$ca_crt" "${admin_path}/msp/cacerts/ca.crt"
    rm "${admin_path}/msp/cert.csr"
    
    # --- 5. Tạo chứng chỉ cho USERS (chỉ cho peer org) ---
    local user1_path=""
    local user2_path=""
    if [ "$org_type" = "peer" ]; then
        # === SỬA LỖI Ở ĐÂY: Dùng user1 (viết thường) ===
        user1_path="${msp_dir}/users/user1@${domain}"
        echo "---> Tạo chứng chỉ cho User: user1@${domain}"
        mkdir -p "${user1_path}/msp/cacerts" "${user1_path}/msp/keystore" "${user1_path}/msp/signcerts"
        openssl ecparam -name prime256v1 -genkey -noout -out "${user1_path}/msp/keystore/priv_sk"
        openssl req -new -key "${user1_path}/msp/keystore/priv_sk" -out "${user1_path}/msp/user.csr" -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${org_msp_name}/OU=client/CN=user1@${domain}"
        openssl x509 -req -in "${user1_path}/msp/user.csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial -out "${user1_path}/msp/signcerts/cert.pem" -days 365 -sha256
        cp "$ca_crt" "${user1_path}/msp/cacerts/ca.crt"
        rm "${user1_path}/msp/user.csr"

        # === SỬA LỖI Ở ĐÂY: Dùng user2 (viết thường) ===
        user2_path="${msp_dir}/users/user2@${domain}"
        echo "---> Tạo chứng chỉ cho User: user2@${domain}"
        mkdir -p "${user2_path}/msp/cacerts" "${user2_path}/msp/keystore" "${user2_path}/msp/signcerts"
        openssl ecparam -name prime256v1 -genkey -noout -out "${user2_path}/msp/keystore/priv_sk"
        openssl req -new -key "${user2_path}/msp/keystore/priv_sk" -out "${user2_path}/msp/user.csr" -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${org_msp_name}/OU=client/CN=user2@${domain}"
        openssl x509 -req -in "${user2_path}/msp/user.csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial -out "${user2_path}/msp/signcerts/cert.pem" -days 365 -sha256
        cp "$ca_crt" "${user2_path}/msp/cacerts/ca.crt"
        rm "${user2_path}/msp/user.csr"
    fi

    # --- 6. Sao chép AdminCerts vào đúng vị trí ---
    cp "${admin_path}/msp/signcerts/cert.pem" "${msp_dir}/msp/admincerts/cert.pem"
    cp "${admin_path}/msp/signcerts/cert.pem" "${node_path}/msp/admincerts/cert.pem"

    # --- 7. Tạo và phân phối config.yaml ---
    echo "---> Tạo và phân phối config.yaml"
    cat > "${msp_dir}/msp/config.yaml" << EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/ca.crt
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/ca.crt
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/ca.crt
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/ca.crt
    OrganizationalUnitIdentifier: orderer
RevocationList:
  - crls/ca.crl
EOF
    
    # Copy file config.yaml vừa tạo tới tất cả các identity
    cp "${msp_dir}/msp/config.yaml" "${node_path}/msp/config.yaml"
    cp "${msp_dir}/msp/config.yaml" "${admin_path}/msp/config.yaml"
    if [ -n "$user1_path" ]; then
        cp "${msp_dir}/msp/config.yaml" "${user1_path}/msp/config.yaml"
    fi
    if [ -n "$user2_path" ]; then
        cp "${msp_dir}/msp/config.yaml" "${user2_path}/msp/config.yaml"
    fi
    
    echo "✅ Chứng chỉ và CRL đã tạo cho $org_name"
}


# === TẠO DOCKER COMPOSE (NO TLS) - PHIÊN BẢN ĐÃ SỬA LỖI PORT ===
generate_docker_compose() {
    source .env.msp
    
    echo "== Tạo Docker Compose (TLS tắt) với MSP: =="
    echo "- SmartBankA: $SMARTBANKA_MSP_ID"
    echo "- SmartBankB: $SMARTBANKB_MSP_ID"
    echo "- Orderer: $ORDERER_MSP_ID"
    
    cat > docker-compose.yaml << EOF
version: '3.7'
networks:
  smartbank_net:
    name: ${NETWORK_NAME}
services:
  orderer.example.com:
    image: hyperledger/fabric-orderer:2.4.9
    container_name: orderer.example.com
    environment:
      - FABRIC_LOGGING_SPEC=INFO
      - ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
      - ORDERER_GENERAL_GENESISMETHOD=file
      - ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/orderer.genesis.block
      - ORDERER_GENERAL_LOCALMSPID=${ORDERER_MSP_ID}
      - ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp
      - ORDERER_GENERAL_TLS_ENABLED=false
    command: orderer
    ports:
      - "${ORDERER_PORT}:7050"
    volumes:
      - ./config/genesis.block:/var/hyperledger/orderer/orderer.genesis.block
      - ./crypto-config/ordererOrganizations/example.com/orderers/orderer.example.com/msp:/var/hyperledger/orderer/msp
    networks:
      - smartbank_net
  peer0.smartbanka.com:
    image: hyperledger/fabric-peer:2.4.9
    container_name: peer0.smartbanka.com
    environment:
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_ID=peer0.smartbanka.com
      - CORE_PEER_ADDRESS=peer0.smartbanka.com:7051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:7051
      - CORE_PEER_CHAINCODEADDRESS=peer0.smartbanka.com:7052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.smartbanka.com:7051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.smartbanka.com:7051
      - CORE_PEER_LOCALMSPID=${SMARTBANKA_MSP_ID}
      - CORE_PEER_TLS_ENABLED=false
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=${NETWORK_NAME}
    ports:
      - "${PEER_SMARTBANKA_PORT}:7051"
    volumes:
      - /var/run/:/host/var/run/
      - ./crypto-config/peerOrganizations/smartbanka.com/peers/peer0.smartbanka.com/msp:/etc/hyperledger/fabric/msp
    networks:
      - smartbank_net

  # === PHẦN SỬA LỖI CHO SMARTBANKB ===
  peer0.smartbankb.com:
    image: hyperledger/fabric-peer:2.4.9
    container_name: peer0.smartbankb.com
    environment:
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_ID=peer0.smartbankb.com
      - CORE_PEER_ADDRESS=peer0.smartbankb.com:8051
      - CORE_PEER_LISTENADDRESS=0.0.0.0:8051  # <-- SỬA TỪ 7051 THÀNH 8051
      - CORE_PEER_CHAINCODEADDRESS=peer0.smartbankb.com:7052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_GOSSIP_BOOTSTRAP=peer0.smartbankb.com:8051
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0.smartbankb.com:8051
      - CORE_PEER_LOCALMSPID=${SMARTBANKB_MSP_ID}
      - CORE_PEER_TLS_ENABLED=false
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=${NETWORK_NAME}
    ports:
      - "${PEER_SMARTBANKB_PORT}:8051" # <-- SỬA TỪ 7051 THÀNH 8051
    volumes:
      - /var/run/:/host/var/run/
      - ./crypto-config/peerOrganizations/smartbankb.com/peers/peer0.smartbankb.com/msp:/etc/hyperledger/fabric/msp
    networks:
      - smartbank_net

  cli:
    image: hyperledger/fabric-tools:2.4.9
    container_name: cli
    tty: true
    stdin_open: true
    environment:
      - GOPATH=/opt/gopath
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_ID=cli
      - CORE_PEER_ADDRESS=peer0.smartbanka.com:7051
      - CORE_PEER_LOCALMSPID=${SMARTBANKA_MSP_ID}
      - CORE_PEER_TLS_ENABLED=false
      - CORE_PEER_MSPCONFIGPATH=/opt/crypto/peerOrganizations/smartbanka.com/users/Admin@smartbanka.com/msp
    command: /bin/bash
    volumes:
      - /var/run/:/host/var/run/
      - ./crypto-config:/opt/crypto
      - ./config:/opt/channel-artifacts
      - ./chaincode:/opt/gopath/src/chaincode
    networks:
      - smartbank_net
    depends_on:
      - orderer.example.com
      - peer0.smartbanka.com
      - peer0.smartbankb.com
EOF
}

# === TẠO CONFIGTX ===
generate_configtx() {
    source .env.msp
    
    cat > configtx.yaml << EOF
Organizations:
  - &OrdererOrg
    Name: ${ORDERER_MSP_ID}
    ID: ${ORDERER_MSP_ID}
    MSPDir: crypto-config/ordererOrganizations/example.com/msp
    Policies:
      Readers:
        Type: Signature
        Rule: "OR('${ORDERER_MSP_ID}.member')"
      Writers:
        Type: Signature
        Rule: "OR('${ORDERER_MSP_ID}.member')"
      Admins:
        Type: Signature
        Rule: "OR('${ORDERER_MSP_ID}.admin')"
    OrdererEndpoints:
      - orderer.example.com:7050

  - &SmartBankA
    Name: ${SMARTBANKA_MSP_ID}
    ID: ${SMARTBANKA_MSP_ID}
    MSPDir: crypto-config/peerOrganizations/smartbanka.com/msp
    Policies:
      Readers:
        Type: Signature
        Rule: "OR('${SMARTBANKA_MSP_ID}.admin', '${SMARTBANKA_MSP_ID}.peer', '${SMARTBANKA_MSP_ID}.client')"
      Writers:
        Type: Signature
        Rule: "OR('${SMARTBANKA_MSP_ID}.admin', '${SMARTBANKA_MSP_ID}.client')"
      Admins:
        Type: Signature
        Rule: "OR('${SMARTBANKA_MSP_ID}.admin')"
      Endorsement:
        Type: Signature
        Rule: "OR('${SMARTBANKA_MSP_ID}.peer')"
    AnchorPeers:
      - Host: peer0.smartbanka.com
        Port: 7051

  - &SmartBankB
    Name: ${SMARTBANKB_MSP_ID}
    ID: ${SMARTBANKB_MSP_ID}
    MSPDir: crypto-config/peerOrganizations/smartbankb.com/msp
    Policies:
      Readers:
        Type: Signature
        Rule: "OR('${SMARTBANKB_MSP_ID}.admin', '${SMARTBANKB_MSP_ID}.peer', '${SMARTBANKB_MSP_ID}.client')"
      Writers:
        Type: Signature
        Rule: "OR('${SMARTBANKB_MSP_ID}.admin', '${SMARTBANKB_MSP_ID}.client')"
      Admins:
        Type: Signature
        Rule: "OR('${SMARTBANKB_MSP_ID}.admin')"
      Endorsement:
        Type: Signature
        Rule: "OR('${SMARTBANKB_MSP_ID}.peer')"
    AnchorPeers:
      - Host: peer0.smartbankb.com
        Port: 8051

Capabilities:
  Channel: &ChannelCapabilities
    V2_0: true
  Orderer: &OrdererCapabilities
    V2_0: true
  Application: &ApplicationCapabilities
    V2_0: true

Application: &ApplicationDefaults
  Organizations:
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
    Endorsement:
      Type: ImplicitMeta
      Rule: "MAJORITY Endorsement"
  Capabilities:
    <<: *ApplicationCapabilities

Orderer: &OrdererDefaults
  OrdererType: solo
  Addresses:
    - orderer.example.com:7050
  BatchTimeout: 2s
  BatchSize:
    MaxMessageCount: 10
    AbsoluteMaxBytes: 99 MB
    PreferredMaxBytes: 512 KB
  Organizations:
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
    BlockValidation:
      Type: ImplicitMeta
      Rule: "ANY Writers"
  Capabilities:
    <<: *OrdererCapabilities

Channel: &ChannelDefaults
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
  Capabilities:
    <<: *ChannelCapabilities

Profiles:
  TwoOrgsOrdererGenesis:
    <<: *ChannelDefaults
    Orderer:
      <<: *OrdererDefaults
      Organizations:
        - *OrdererOrg
      Capabilities:
        <<: *OrdererCapabilities
    Consortiums:
      SampleConsortium:
        Organizations:
          - *SmartBankA
          - *SmartBankB

  TwoOrgsChannel:
    <<: *ChannelDefaults
    Consortium: SampleConsortium
    Application:
      <<: *ApplicationDefaults
      Organizations:
        - *SmartBankA
        - *SmartBankB
      Capabilities:
        <<: *ApplicationCapabilities
EOF
}

# === HÀM THỰC THI CHÍNH ===
main() {
    echo "Bắt đầu triển khai với chứng chỉ OpenSSL có sẵn..."
    
    cleanup
    validate_certs
    
    echo '============================================================'
    echo "==                TẠO CHỨNG CHỈ NODE & ADMIN              =="
    echo '============================================================'
    create_simple_certs "peer" "smartbanka"
    create_simple_certs "peer" "smartbankb"
    create_simple_certs "orderer" "orderer"
    echo "✅ Chứng chỉ đã được tạo từ OpenSSL có sẵn."
    
    echo '============================================================'
    echo "==                       TẠO CẤU HÌNH                     =="
    echo '============================================================'
    generate_docker_compose
    generate_configtx
    echo "✅ Cấu hình đã được tạo."
    
    echo "### TẠO GENESIS BLOCK & CHANNEL TX ###"
    configtxgen -profile TwoOrgsOrdererGenesis -channelID system-channel -outputBlock ./config/genesis.block
    configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./config/smartbank-channel.tx -channelID smartbank-channel
    echo "✅ Genesis block và channel transaction đã được tạo."
    
    echo "### KHỞI ĐỘNG MẠNG ###"
    docker-compose up -d
    echo "Đang chờ các node khởi động..."
    sleep 10
    echo "✅ Mạng đã khởi động."
    
    echo '============================================================'
    echo "==                  TẠO & JOIN CHANNEL                    =="
    echo '============================================================'
    docker exec cli peer channel create -o orderer.example.com:7050 -c smartbank-channel -f /opt/channel-artifacts/smartbank-channel.tx
    sleep 3
    
    echo "Peer của SmartBankA đang join channel..."
    docker exec cli peer channel join -b smartbank-channel.block
    
    echo "Peer của SmartBankB đang join channel..."
    source .env.msp
    docker exec -e "CORE_PEER_LOCALMSPID=${SMARTBANKB_MSP_ID}" \
        -e "CORE_PEER_ADDRESS=peer0.smartbankb.com:8051" \
        -e "CORE_PEER_TLS_ENABLED=false" \
        -e "CORE_PEER_MSPCONFIGPATH=/opt/crypto/peerOrganizations/smartbankb.com/users/Admin@smartbankb.com/msp" \
        cli peer channel join -b smartbank-channel.block
    echo "✅ Channel đã được tạo và các peer đã join."

    echo '============================================================'
    echo "==                CẬP NHẬT ANCHOR PEERS                   =="
    echo '============================================================'
    source .env.msp

    echo "Tạo file cập nhật cho SmartBankA..."
    configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./config/SmartBankAanchors.tx -channelID smartbank-channel -asOrg ${SMARTBANKA_MSP_ID}

    echo "Tạo file cập nhật cho SmartBankB..."
    configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./config/SmartBankBanchors.tx -channelID smartbank-channel -asOrg ${SMARTBANKB_MSP_ID}
    
    echo "Gửi cập nhật anchor peer cho SmartBankA..."
    docker exec cli peer channel update -o orderer.example.com:7050 -c smartbank-channel -f /opt/channel-artifacts/SmartBankAanchors.tx

    echo "Gửi cập nhật anchor peer cho SmartBankB..."
    docker exec -e "CORE_PEER_LOCALMSPID=${SMARTBANKB_MSP_ID}" \
        -e "CORE_PEER_ADDRESS=peer0.smartbankb.com:8051" \
        -e "CORE_PEER_TLS_ENABLED=false" \
        -e "CORE_PEER_MSPCONFIGPATH=/opt/crypto/peerOrganizations/smartbankb.com/users/Admin@smartbankb.com/msp" \
        cli peer channel update -o orderer.example.com:7050 -c smartbank-channel -f /opt/channel-artifacts/SmartBankBanchors.tx
    echo "✅ Anchor peers đã được cập nhật."
    
    echo '============================================================'
    echo "==                       KIỂM TRA                         =="
    echo '============================================================'
    echo "Kiểm tra danh sách kênh của peer SmartBankA:"
    docker exec cli peer channel list
    echo "Kiểm tra trạng thái anchor của các peer"
    docker exec cli bash -c '
      peer channel fetch config config_block.pb -o orderer.example.com:7050 -c smartbank-channel &>/dev/null &&
      configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config | jq -r ".channel_group.groups.Application.groups[].values.AnchorPeers.value.anchor_peers[].host"
    '

    echo '============================================================'
    echo "== HOÀN TẤT! SmartBank Fabric - OpenSSL có sẵn + CRL!    =="
    echo "== Sẵn sàng: docker exec -it cli bash =="
    echo '============================================================'
}

main "$@"