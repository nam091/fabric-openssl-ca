#!/bin/bash
# =================================================================
# == KỊCH BẢN TƯƠNG TÁC ĐỂ THU HỒI CHỨNG CHỈ (PKI/CRL)          ==
# == PHIÊN BẢN SỬA LỖI ĐƯỜNG DẪN PHÂN PHỐI CRL                  ==
# =================================================================

set -e

# --- HÀM LẤY THÔNG TIN TỪ NGƯỜI DÙNG VÀ ĐỊNH NGHĨA BIẾN ---
get_user_info() {
    clear
    echo "======================================================="
    echo "==   NHẬP THÔNG TIN CHỨNG CHỈ CẦN THU HỒI           =="
    echo "======================================================="
    read -p "Nhập Tên Tổ chức (smartbanka hoặc smartbankb): " ORG_NAME
    read -p "Nhập User ID (ví dụ: user1): " USER_ID

    if [[ "$ORG_NAME" != "smartbanka" && "$ORG_NAME" != "smartbankb" ]]; then
        echo "LỖI: Tên tổ chức không hợp lệ!"
        sleep 2
        get_user_info
    fi
    if [ -z "$USER_ID" ]; then
        echo "LỖI: User ID không được để trống!"
        sleep 2
        get_user_info
    fi

    # --- Định nghĩa các biến toàn cục dựa trên input ---
    export DOMAIN="${ORG_NAME}.com"
    export USER_EMAIL="${USER_ID}@${DOMAIN}"
    export CA_DIR="external-cas/${ORG_NAME}-rca"
    export CA_CONFIG="openssl.cnf" 
    export CERT_TO_REVOKE="${PWD}/crypto-config/peerOrganizations/${DOMAIN}/users/${USER_EMAIL}/msp/signcerts/cert.pem"
    # <<< SỬA ĐỔI Ở ĐÂY: Thêm đường dẫn MSP của Peer
    export ORG_MSP_CRL_DIR="${PWD}/crypto-config/peerOrganizations/${DOMAIN}/msp/crls"
    export PEER_MSP_CRL_DIR="${PWD}/crypto-config/peerOrganizations/${DOMAIN}/peers/peer0.${DOMAIN}/msp/crls"
    export PEER_CONTAINER="peer0.${DOMAIN}"
    
    # Kiểm tra xem chứng chỉ của user có tồn tại không
    if [ ! -f "$CERT_TO_REVOKE" ]; then
        echo ""
        echo "LỖI: Không tìm thấy file chứng chỉ của người dùng '${USER_EMAIL}'."
        echo "Đường dẫn kiểm tra: ${CERT_TO_REVOKE}"
        echo "Vui lòng kiểm tra lại thông tin."
        sleep 4
        get_user_info
    fi
}

# --- CÁC HÀM THỰC THI CHỨC NĂNG (HELPER FUNCTIONS) ---
revoke_cert_in_db() {
    echo "--> Bước 1: Thu hồi chứng chỉ trong database của CA..."
    (cd "${CA_DIR}" && openssl ca -config "${CA_CONFIG}" -revoke "${CERT_TO_REVOKE}")
    echo "✅ Đã cập nhật trạng thái 'Revoked' trong file index.txt."
}

generate_new_crl() {
    echo "--> Bước 2: Tạo lại file CRL mới..."
    (cd "${CA_DIR}" && openssl ca -config "${CA_CONFIG}" -gencrl -out "crl/ca.crl")
    echo "✅ Đã tạo file CRL mới tại ${CA_DIR}/crl/ca.crl"
}

distribute_crl() {
    if [ ! -f "${CA_DIR}/crl/ca.crl" ]; then
        echo "LỖI: Không có file CRL mới để phân phối."
        return 1
    fi
    # <<< SỬA ĐỔI Ở ĐÂY: Phân phối CRL đến cả 2 nơi
    echo "--> Bước 3: Phân phối file CRL vào các thư mục MSP..."
    
    # Phân phối cho Org MSP (dùng cho configtxgen)
    mkdir -p "${ORG_MSP_CRL_DIR}"
    cp "${CA_DIR}/crl/ca.crl" "${ORG_MSP_CRL_DIR}/"
    echo "✅ Đã sao chép CRL đến Org MSP: ${ORG_MSP_CRL_DIR}"

    # Phân phối cho Peer MSP (quan trọng nhất, để peer nạp vào bộ nhớ)
    mkdir -p "${PEER_MSP_CRL_DIR}"
    cp "${CA_DIR}/crl/ca.crl" "${PEER_MSP_CRL_DIR}/"
    echo "✅ Đã sao chép CRL đến Peer MSP: ${PEER_MSP_CRL_DIR}"
}

show_restart_instructions() {
    echo "------------------------------------------------------------------"
    echo "LƯU Ý: Để Peer áp dụng CRL mới ngay lập tức, cần khởi động lại Peer."
    echo "Lệnh để khởi động lại:"
    echo ""
    echo "   docker restart ${PEER_CONTAINER}"
    echo ""
    echo "Kịch bản này không tự động chạy lệnh trên để đảm bảo an toàn."
    echo "------------------------------------------------------------------"
}

# === [CHỨC NĂNG MỚI] HÀM GỘP 3 BƯỚC ===
perform_full_pki_revocation() {
    echo "### Bắt đầu quy trình thu hồi PKI đầy đủ ###"
    if revoke_cert_in_db && generate_new_crl && distribute_crl; then
        echo ""
        echo "✅ HOÀN TẤT: Đã thu hồi chứng chỉ và tạo/phân phối CRL mới thành công."
        echo ""
        show_restart_instructions
    else
        echo ""
        echo "❌ Đã có lỗi xảy ra trong quá trình thu hồi. Vui lòng kiểm tra log."
    fi
}

# --- HÀM CHÍNH HIỂN THỊ MENU ---
main_menu() {
    clear
    echo "======================================================="
    echo "==     QUẢN LÝ THU HỒI CHỨNG CHỈ (CRL) - TƯƠNG TÁC    =="
    echo "======================================================="
    echo "Đang thao tác với User: ${USER_EMAIL}"
    echo "Tổ chức:               ${ORG_NAME}"
    echo "-------------------------------------------------------"
    echo "Vui lòng chọn chức năng:"
    echo "  1. [GỘP] Thực hiện thu hồi và tạo/phân phối CRL mới"
    echo "  2. [Xem] Hướng dẫn khởi động lại Peer"
    echo "  3. Nhập lại thông tin User/Org khác"
    echo "  4. Thoát"
    echo ""
}

# --- VÒNG LẶP CHÍNH CỦA KỊCH BẢN ---
get_user_info

while true; do
    main_menu
    read -p "Lựa chọn của  [1-4]: " choice

    case $choice in
    1)
        perform_full_pki_revocation
        ;;
    2)
        show_restart_instructions
        ;;
    3)
        get_user_info
        ;;
    4)
        echo "Tạm biệt !"
        exit 0
        ;;
    *)
        echo "Lựa chọn không hợp lệ. Vui lòng thử lại."
        ;;
    esac
    echo ""
    read -p "Nhấn [Enter] để tiếp tục..."
done