#!/bin/bash
# =====================================================================
# == INIT_CHAINCODE.SH - PHIÊN BẢN SỬA LỖI MSP ID                   ==
# =====================================================================

# Dừng ngay khi có lỗi
set -e

# === SỬA LỖI Ở ĐÂY: Đọc các biến MSP ID từ file .env.msp ===
if [ ! -f ".env.msp" ]; then
    echo "LỖI: Không tìm thấy file .env.msp. Vui lòng chạy lại ./deploy.sh trước."
    exit 1
fi
source .env.msp

echo "### DỌN DẸP CÁC CHAINCODE CŨ ###"
docker exec cli rm -f "/opt/gopath/src/chaincode/${CC_PACKAGE_FILE}" >/dev/null 2>&1 || true
echo "✅ Đã dọn dẹp các gói cũ."

# --- PHẦN 1: ĐỊNH NGHĨA CÁC BIẾN CỐ ĐỊNH ---
echo "### BƯỚC 1: ĐỊNH NGHĨA BIẾN CHAINCODE ###"
CHANNEL_NAME="smartbank-channel"
CC_NAME="bank"
CC_SRC_PATH="/opt/gopath/src/chaincode/bank"
CC_VERSION="1.0"
CC_SEQUENCE="1"
CC_LABEL="bank_v1"
CC_PACKAGE_FILE="${CC_NAME}_cc.tar.gz"
echo "✅ Đã định nghĩa biến."

# --- HÀM HỖ TRỢ ĐỂ THAY ĐỔI VAI TRÒ ---
set_org_context() {
  ORG_NAME=$1
  if [ "$ORG_NAME" == "smartbanka" ]; then
    # === SỬA LỖI Ở ĐÂY: Dùng biến MSP ID đã đọc ===
    export CORE_PEER_LOCALMSPID="$SMARTBANKA_MSP_ID"
    export CORE_PEER_ADDRESS="peer0.smartbanka.com:7051"
    export CORE_PEER_MSPCONFIGPATH="/opt/crypto/peerOrganizations/smartbanka.com/users/Admin@smartbanka.com/msp"
  elif [ "$ORG_NAME" == "smartbankb" ]; then
    # === SỬA LỖI Ở ĐÂY: Dùng biến MSP ID đã đọc ===
    export CORE_PEER_LOCALMSPID="$SMARTBANKB_MSP_ID"
    export CORE_PEER_ADDRESS="peer0.smartbankb.com:8051"
    export CORE_PEER_MSPCONFIGPATH="/opt/crypto/peerOrganizations/smartbankb.com/users/Admin@smartbankb.com/msp"
  else
    echo "LỖI: Không tìm thấy tổ chức ${ORG_NAME}"
    exit 1
  fi
  echo "--- Đang thực thi với vai trò Admin của: ${ORG_NAME} ($CORE_PEER_LOCALMSPID) ---"
}

# --- PHẦN 2: ĐÓNG GÓI CHAINCODE ---
echo "### BƯỚC 2: ĐÓNG GÓI CHAINCODE ###"
docker exec cli peer lifecycle chaincode package "${CC_PACKAGE_FILE}" \
  --path "${CC_SRC_PATH}" \
  --lang golang \
  --label "${CC_LABEL}"
docker exec cli mv "${CC_PACKAGE_FILE}" /opt/gopath/src/chaincode/
echo "✅ Đã đóng gói chaincode."


# --- PHẦN 3: CÀI ĐẶT CHAINCODE LÊN CÁC PEER ---
echo "### BƯỚC 3: CÀI ĐẶT CHAINCODE LÊN PEER ###"
set_org_context smartbanka
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer lifecycle chaincode install "/opt/gopath/src/chaincode/${CC_PACKAGE_FILE}"
echo "✅ Đã cài đặt lên peer0.smartbanka.com"

set_org_context smartbankb
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer lifecycle chaincode install "/opt/gopath/src/chaincode/${CC_PACKAGE_FILE}"
echo "✅ Đã cài đặt lên peer0.smartbankb.com"


# --- PHẦN 4: PHÊ DUYỆT CHAINCODE ---
echo "### BƯỚC 4: PHÊ DUYỆT ĐỊNH NGHĨA CHAINCODE ###"
PACKAGE_ID=$(docker exec cli peer lifecycle chaincode queryinstalled | grep "Package ID: ${CC_LABEL}:" | sed -n 's/^Package ID: //; s/, Label:.*$//p' | head -1)
echo "Package ID là: ${PACKAGE_ID}"
sleep 3

set_org_context smartbanka
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer lifecycle chaincode approveformyorg \
    -o orderer.example.com:7050 \
    --channelID "${CHANNEL_NAME}" --name "${CC_NAME}" --version "${CC_VERSION}" --sequence "${CC_SEQUENCE}" \
    --package-id "${PACKAGE_ID}" \
    --signature-policy "OR('$SMARTBANKA_MSP_ID.member','$SMARTBANKB_MSP_ID.member')" \
    --init-required
echo "✅ SmartBankA đã phê duyệt."

set_org_context smartbankb
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer lifecycle chaincode approveformyorg \
    -o orderer.example.com:7050 \
    --channelID "${CHANNEL_NAME}" --name "${CC_NAME}" --version "${CC_VERSION}" --sequence "${CC_SEQUENCE}" \
    --package-id "${PACKAGE_ID}" \
    --signature-policy "OR('$SMARTBANKA_MSP_ID.member','$SMARTBANKB_MSP_ID.member')" \
    --init-required
echo "✅ SmartBankB đã phê duyệt."


# --- PHẦN 5: COMMIT CHAINCODE LÊN CHANNEL ---
echo "### BƯỚC 5: COMMIT ĐỊNH NGHĨA CHAINCODE ###"
set_org_context smartbanka
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer lifecycle chaincode commit \
    -o orderer.example.com:7050 \
    --channelID "${CHANNEL_NAME}" --name "${CC_NAME}" --version "${CC_VERSION}" --sequence "${CC_SEQUENCE}" \
    --peerAddresses peer0.smartbanka.com:7051 \
    --peerAddresses peer0.smartbankb.com:8051 \
    --signature-policy "OR('$SMARTBANKA_MSP_ID.member','$SMARTBANKB_MSP_ID.member')" \
    --init-required
echo "✅ Đã commit định nghĩa chaincode."

docker exec cli peer lifecycle chaincode querycommitted --channelID "${CHANNEL_NAME}" --name "${CC_NAME}"


# --- PHẦN 6: KHỞI TẠO CHAINCODE ---
echo "### BƯỚC 6: KHỞI TẠO CHAINCODE (Init) ###"
set_org_context smartbanka
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer chaincode invoke \
    -o orderer.example.com:7050 \
    --isInit -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses peer0.smartbanka.com:7051 \
    --peerAddresses peer0.smartbankb.com:8051 \
    -c '{"function":"InitLedger","args":[]}'

echo "--> Chờ 5 giây để các block được đồng bộ..."
sleep 5
echo "✅ Đã khởi tạo chaincode thành công!"


# --- PHẦN 7: MÔ PHỎNG GIAO DỊCH CỦA CLIENT ---
echo ""
echo "### BƯỚC 7: MÔ PHỎNG GIAO DỊCH CỦA CLIENT ###"
USER_A_MSP_PATH="/opt/crypto/peerOrganizations/smartbanka.com/users/user1@smartbanka.com/msp"
USER_B_MSP_PATH="/opt/crypto/peerOrganizations/smartbankb.com/users/user1@smartbankb.com/msp"
PEER_A_ADDRESS="peer0.smartbanka.com:7051"
PEER_B_ADDRESS="peer0.smartbankb.com:8051"

echo '============================================================'
echo "--> Client của SmartBankA truy vấn số dư của user1@smartbanka.com"
docker exec \
  -e "CORE_PEER_ADDRESS=${PEER_A_ADDRESS}" \
  -e "CORE_PEER_MSPCONFIGPATH=${USER_A_MSP_PATH}" \
  cli peer chaincode query -C "${CHANNEL_NAME}" -n "${CC_NAME}" -c '{"function":"Query","args":["user1@smartbanka.com"]}'
echo '============================================================'
echo "--> Số dư ban đầu của user2@smartbankb.com là:"
docker exec \
  -e "CORE_PEER_ADDRESS=${PEER_A_ADDRESS}" \
  -e "CORE_PEER_MSPCONFIGPATH=${USER_A_MSP_PATH}" \
  cli peer chaincode query -C "${CHANNEL_NAME}" -n "${CC_NAME}" -c '{"function":"Query","args":["user2@smartbankb.com"]}'

echo '============================================================'
echo "--> User1@smartbanka.com thực hiện chuyển 1,000,000 cho user2@smartbankb.com"
docker exec \
  -e "CORE_PEER_ADDRESS=${PEER_A_ADDRESS}" \
  -e "CORE_PEER_MSPCONFIGPATH=${USER_A_MSP_PATH}" \
  cli peer chaincode invoke \
    -o orderer.example.com:7050 \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER_A_ADDRESS}" \
    --peerAddresses "${PEER_B_ADDRESS}" \
    -c '{"function":"Transfer","args":["user1@smartbanka.com", "user2@smartbankb.com", "1000000"]}'

sleep 3
echo "--> Client của SmartBankA truy vấn lại số dư của user2@smartbankb.com để xác nhận"
docker exec \
  -e "CORE_PEER_ADDRESS=${PEER_B_ADDRESS}" \
  -e "CORE_PEER_MSPCONFIGPATH=${USER_B_MSP_PATH}" \
  -e "CORE_PEER_LOCALMSPID=${SMARTBANKB_MSP_ID}" \
  cli peer chaincode query -C "${CHANNEL_NAME}" -n "${CC_NAME}" -c '{"function":"Query","args":["user2@smartbankb.com"]}'

echo "✅ Đã mô phỏng xong giao dịch của Client!"


# --- PHẦN 8: MÔ PHỎNG VIỆC ADMIN THU HỒI TÀI KHOẢN ---
echo ""
echo "### BƯỚC 8: MÔ PHỎNG VIỆC ADMIN THU HỒI TÀI KHOẢN ###"
set_org_context smartbanka
echo "--> Admin của SmartBankA thực hiện thu hồi tài khoản user2@smartbanka.com"
docker exec \
  -e CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID \
  -e CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS \
  -e CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH \
  cli peer chaincode invoke \
    -o orderer.example.com:7050 \
    -C "${CHANNEL_NAME}" -n "${CC_NAME}" \
    --peerAddresses "${PEER_A_ADDRESS}" \
    --peerAddresses "${PEER_B_ADDRESS}" \
    -c '{"function":"RevokeAccount","args":["user2@smartbanka.com"]}'

sleep 3
echo "--> Client thử truy vấn lại tài khoản đã bị thu hồi (sẽ báo lỗi)..."
docker exec \
  -e "CORE_PEER_ADDRESS=${PEER_A_ADDRESS}" \
  -e "CORE_PEER_MSPCONFIGPATH=${USER_A_MSP_PATH}" \
  cli peer chaincode query -C "${CHANNEL_NAME}" -n "${CC_NAME}" -c '{"function":"Query","args":["user2@smartbanka.com"]}' || \
  echo "THÀNH CÔNG: Giao dịch bị từ chối đúng như mong đợi vì tài khoản đã bị khóa!"

echo "✅ Đã mô phỏng xong kịch bản thu hồi quyền!"
echo ""
echo "======================================================"
echo "===     KỊCH BẢN TRIỂN KHAI CHAINCODE HOÀN TẤT     ==="
echo "======================================================"