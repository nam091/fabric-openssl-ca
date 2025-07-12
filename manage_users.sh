#!/bin/bash
# =================================================================
# == MANAGE_USERS.SH - PHIÊN BẢN SỬA LỖI LOGIC USER ID           ==
# =================================================================

set -e

# --- HÀM IN HƯỚNG DẪN SỬ DỤNG ---
print_usage() {
    echo "Cách dùng: ./manage_users.sh [HÀNH ĐỘNG] [THAM_SỐ...]"
    echo ""
    echo "Ví dụ:"
    echo "  ./manage_users.sh register smartbanka user3 50000000"
    echo "  ./manage_users.sh query smartbankb user2"
    echo "  ./manage_users.sh revoke smartbankb user2"
    echo "  ./manage_users.sh reactivate smartbankb user2"
    echo "  ./manage_users.sh transfer smartbanka user1 smartbankb user2 100000"
    echo ""
    echo "Hành động:"
    echo "  register   : Đăng ký một người dùng mới và tạo tài khoản trên ledger."
    echo "  query      : Truy vấn thông tin tài khoản của người dùng."
    echo "  revoke     : Thu hồi quyền truy cập của người dùng."
    echo "  reactivate : Kích hoạt lại tài khoản đã bị thu hồi."
    echo "  transfer   : Chuyển tiền giữa hai tài khoản."
    echo ""
    echo "Tên Org: smartbanka | smartbankb"
}

# --- HÀM THIẾT LẬP BỐI CẢNH CHO ADMIN CỦA MỘT ORG ---
set_admin_context() {
    ORG_NAME=$1
    
    source .env.msp

    if [ "$ORG_NAME" == "smartbanka" ]; then
        export CORE_PEER_LOCALMSPID="$SMARTBANKA_MSP_ID"
        export CORE_PEER_ADDRESS="peer0.smartbanka.com:7051"
        export CORE_PEER_MSPCONFIGPATH="/opt/crypto/peerOrganizations/smartbanka.com/users/Admin@smartbanka.com/msp"
    elif [ "$ORG_NAME" == "smartbankb" ]; then
        export CORE_PEER_LOCALMSPID="$SMARTBANKB_MSP_ID"
        export CORE_PEER_ADDRESS="peer0.smartbankb.com:8051"
        export CORE_PEER_MSPCONFIGPATH="/opt/crypto/peerOrganizations/smartbankb.com/users/Admin@smartbankb.com/msp"
    else
        echo "LỖI: Không tìm thấy tổ chức ${ORG_NAME}"
        exit 1
    fi
    echo "--- Đang thực thi với vai trò Admin của ${ORG_NAME} ---"
}

# === SỬA LỖI Ở ĐÂY: Hàm register_user bây giờ sẽ dùng USER_ID đầy đủ (vd: user3) ===
register_user() {
    ORG_NAME=$1
    USER_ID=$2 # vd: user3
    INITIAL_BALANCE=$3
    DOMAIN="${ORG_NAME}.com"
    USER_EMAIL="${USER_ID}@${DOMAIN}" # -> user3@smartbanka.com
    
    echo "### Bắt đầu đăng ký người dùng mới: ${USER_EMAIL} ###"

    USER_MSP_DIR="${PWD}/crypto-config/peerOrganizations/${DOMAIN}/users/${USER_EMAIL}/msp"
    if [ -d "$USER_MSP_DIR" ]; then
        echo "LỖI: Người dùng ${USER_EMAIL} đã tồn tại trong thư mục crypto-config."
        exit 1
    fi
    echo "--> Đang tạo chứng chỉ cho ${USER_EMAIL}..."
    CA_DIR_PATH="${PWD}/external-cas/${ORG_NAME}-rca"
    CA_KEY_PATH="${CA_DIR_PATH}/private/ca.key"
    CA_CRT_PATH="${CA_DIR_PATH}/certs/ca.crt"
    ORG_MSP_NAME=$(openssl x509 -in $CA_CRT_PATH -noout -subject | sed -n 's/.*O=\([^,]*\).*/\1/p')

    mkdir -p "${USER_MSP_DIR}/cacerts" "${USER_MSP_DIR}/keystore" "${USER_MSP_DIR}/signcerts" "${USER_MSP_DIR}/crls"
    
    openssl ecparam -name prime256v1 -genkey -noout -out "${USER_MSP_DIR}/keystore/priv_sk"
    openssl req -new -key "${USER_MSP_DIR}/keystore/priv_sk" -out "${USER_MSP_DIR}/user.csr" -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${ORG_MSP_NAME}/OU=client/CN=${USER_EMAIL}"
    openssl x509 -req -in "${USER_MSP_DIR}/user.csr" -CA "$CA_CRT_PATH" -CAkey "$CA_KEY_PATH" -CAcreateserial -out "${USER_MSP_DIR}/signcerts/cert.pem" -days 365 -sha256
    cp "$CA_CRT_PATH" "${USER_MSP_DIR}/cacerts/ca.crt"
    
    cp "${PWD}/crypto-config/peerOrganizations/${DOMAIN}/msp/config.yaml" "${USER_MSP_DIR}/"
    cp -r "${PWD}/crypto-config/peerOrganizations/${DOMAIN}/msp/crls" "${USER_MSP_DIR}/"
    
    rm "${USER_MSP_DIR}/user.csr"
    echo "✅ Đã tạo xong chứng chỉ định danh (Identity) cho người dùng."

    echo "--> Đang tạo tài khoản trên Sổ cái với số dư: ${INITIAL_BALANCE}"
    set_admin_context $ORG_NAME
    
    docker exec \
      -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
      -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
      -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
      cli peer chaincode invoke \
      -o orderer.example.com:7050 \
      -C smartbank-channel -n bank \
      --peerAddresses peer0.smartbanka.com:7051 \
      --peerAddresses peer0.smartbankb.com:8051 \
      -c "{\"function\":\"CreateAccount\",\"args\":[\"${USER_EMAIL}\", \"${INITIAL_BALANCE}\"]}"
    
    echo "✅ Hoàn tất! Người dùng ${USER_EMAIL} đã được tạo và sẵn sàng giao dịch."
}

# === SỬA LỖI Ở ĐÂY: Các hàm sau sẽ nhận và dùng USER_ID đầy đủ (vd: user3) ===
revoke_user() {
    ORG_NAME=$1
    USER_ID=$2 # vd: user3
    DOMAIN="${ORG_NAME}.com"
    USER_EMAIL="${USER_ID}@${DOMAIN}"
    CERT_PATH="${PWD}/crypto-config/peerOrganizations/${DOMAIN}/users/${USER_EMAIL}/msp/signcerts/cert.pem"

    echo "### Bắt đầu thu hồi quyền của người dùng: ${USER_EMAIL} ###"

    if [ ! -f "$CERT_PATH" ]; then
        echo "LỖI: Không tìm thấy chứng chỉ của người dùng ${USER_EMAIL}."
        exit 1
    fi

    echo "--> Bước 1: Thu hồi quyền trên Chaincode..."
    set_admin_context $ORG_NAME
    
    docker exec \
      -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
      -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
      -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
      cli peer chaincode invoke \
      -o orderer.example.com:7050 \
      -C smartbank-channel -n bank \
      --peerAddresses peer0.smartbanka.com:7051 \
      --peerAddresses peer0.smartbankb.com:8051 \
      -c "{\"function\":\"RevokeAccount\",\"args\":[\"${USER_EMAIL}\"]}"
    
    echo "✅ Đã khóa tài khoản trên Sổ cái."
    echo "CẢNH BÁO: Cần chạy kịch bản 'revoke_user_pki.sh' để hoàn tất thu hồi ở tầng hạ tầng."
}

reactivate_user() {
    ORG_NAME=$1
    USER_ID=$2 # vd: user3
    DOMAIN="${ORG_NAME}.com"
    USER_EMAIL="${USER_ID}@${DOMAIN}"

    echo "### Bắt đầu kích hoạt lại tài khoản: ${USER_EMAIL} ###"
    set_admin_context $ORG_NAME

    docker exec \
      -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
      -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
      -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
      cli peer chaincode invoke \
      -o orderer.example.com:7050 \
      -C smartbank-channel -n bank \
      --peerAddresses peer0.smartbanka.com:7051 \
      --peerAddresses peer0.smartbankb.com:8051 \
      -c "{\"function\":\"ReactivateAccount\",\"args\":[\"${USER_EMAIL}\"]}"
    
    echo "✅ Đã gửi yêu cầu kích hoạt lại tài khoản ${USER_EMAIL}."
}

query_user() {
    ORG_NAME=$1
    USER_ID=$2 # vd: user3
    DOMAIN="${ORG_NAME}.com"
    USER_EMAIL="${USER_ID}@${DOMAIN}"

    echo "### Truy vấn thông tin tài khoản: ${USER_EMAIL} ###"
    set_admin_context $ORG_NAME

    docker exec \
      -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
      -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
      -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
      cli peer chaincode query \
      -C smartbank-channel -n bank \
      -c "{\"function\":\"Query\",\"args\":[\"${USER_EMAIL}\"]}"
}

transfer_funds() {
    SENDER_ORG=$1
    SENDER_ID=$2 # vd: user1
    RECIPIENT_ORG=$3
    RECIPIENT_ID=$4 # vd: user2
    AMOUNT=$5

    SENDER_DOMAIN="${SENDER_ORG}.com"
    SENDER_EMAIL="${SENDER_ID}@${SENDER_DOMAIN}"
    RECIPIENT_DOMAIN="${RECIPIENT_ORG}.com"
    RECIPIENT_EMAIL="${RECIPIENT_ID}@${RECIPIENT_DOMAIN}"

    echo "### Bắt đầu chuyển ${AMOUNT} từ ${SENDER_EMAIL} đến ${RECIPIENT_EMAIL} ###"

    # Thiết lập bối cảnh cho người gửi (SENDER)
    source .env.msp
    if [ "$SENDER_ORG" == "smartbanka" ]; then
        SENDER_MSP_ID="$SMARTBANKA_MSP_ID"
        SENDER_PEER_ADDRESS="peer0.smartbanka.com:7051"
    else
        SENDER_MSP_ID="$SMARTBANKB_MSP_ID"
        SENDER_PEER_ADDRESS="peer0.smartbankb.com:8051"
    fi
    
    SENDER_MSP_PATH="/opt/crypto/peerOrganizations/${SENDER_DOMAIN}/users/${SENDER_EMAIL}/msp"
    
    PEER_A_ADDRESS="peer0.smartbanka.com:7051"
    PEER_B_ADDRESS="peer0.smartbankb.com:8051"

    echo "--- Giao dịch được thực hiện bởi ${SENDER_EMAIL} ---"

    docker exec \
      -e "CORE_PEER_LOCALMSPID=${SENDER_MSP_ID}" \
      -e "CORE_PEER_ADDRESS=${SENDER_PEER_ADDRESS}" \
      -e "CORE_PEER_MSPCONFIGPATH=${SENDER_MSP_PATH}" \
      cli peer chaincode invoke \
      -o orderer.example.com:7050 \
      -C smartbank-channel -n bank \
      --peerAddresses "${PEER_A_ADDRESS}" \
      --peerAddresses "${PEER_B_ADDRESS}" \
      -c "{\"function\":\"Transfer\",\"args\":[\"${SENDER_EMAIL}\", \"${RECIPIENT_EMAIL}\", \"${AMOUNT}\"]}"

    echo "✅ Đã gửi yêu cầu chuyển tiền."
}

# --- PHÂN TÍCH THAM SỐ ĐẦU VÀO ---
ACTION=${1:-}
ORG_NAME=${2:-}
USER_ID=${3:-} # Sẽ nhận đầy đủ, vd: user3

if [ -z "$ACTION" ]; then
    print_usage
    exit 1
fi

case $ACTION in
"register")
    INITIAL_BALANCE=${4:-}
    if [ -z "$ORG_NAME" ] || [ -z "$USER_ID" ] || [ -z "$INITIAL_BALANCE" ]; then
        echo "LỖI: Cần cung cấp đủ TÊN_ORG, USER_ID, SỐ_DƯ."
        print_usage
        exit 1
    fi
    register_user $ORG_NAME $USER_ID $INITIAL_BALANCE
    ;;
"revoke")
    if [ -z "$ORG_NAME" ] || [ -z "$USER_ID" ]; then
        echo "LỖI: Cần cung cấp đủ TÊN_ORG, USER_ID."
        print_usage
        exit 1
    fi
    revoke_user $ORG_NAME $USER_ID
    ;;
"reactivate")
    if [ -z "$ORG_NAME" ] || [ -z "$USER_ID" ]; then
        echo "LỖI: Cần cung cấp đủ TÊN_ORG, USER_ID."
        print_usage
        exit 1
    fi
    reactivate_user $ORG_NAME $USER_ID
    ;;
"query")
    if [ -z "$ORG_NAME" ] || [ -z "$USER_ID" ]; then
        echo "LỖI: Cần cung cấp đủ TÊN_ORG, USER_ID."
        print_usage
        exit 1
    fi
    query_user $ORG_NAME $USER_ID
    ;;
"transfer")
    SENDER_ORG=$2
    SENDER_ID=$3
    RECIPIENT_ORG=$4
    RECIPIENT_ID=$5
    AMOUNT=$6
    if [ -z "$SENDER_ORG" ] || [ -z "$SENDER_ID" ] || [ -z "$RECIPIENT_ORG" ] || [ -z "$RECIPIENT_ID" ] || [ -z "$AMOUNT" ]; then
        echo "LỖI: Cần cung cấp đủ thông tin người gửi, người nhận và số tiền."
        print_usage
        exit 1
    fi
    transfer_funds $SENDER_ORG $SENDER_ID $RECIPIENT_ORG $RECIPIENT_ID $AMOUNT
    ;;
*)
    echo "LỖI: Hành động '$ACTION' không hợp lệ."
    print_usage
    exit 1
    ;;
esac

echo "✅ Kịch bản đã thực thi xong!"