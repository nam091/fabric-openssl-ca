#!/bin/bash
# =================================================================
# ==                      GEN-CERT-FIX.SH                        ==
# == TẠO HẠ TẦNG CA ĐẦY ĐỦ VÀ FILE .CNF RIÊNG CHO MỖI ORG        ==
# =================================================================

set -e

# --- HÀM TẠO CẤU TRÚC CA ĐẦY ĐỦ CHO MỘT TỔ CHỨC ---
create_ca_structure() {
  local ORG_NAME=$1
  local ORG_DOMAIN=$2
  local CA_DIR="external-cas/${ORG_NAME}-rca"

  echo "--- Đang tạo cấu trúc CA cho: ${ORG_NAME} ---"
  
  # Tạo cấu trúc thư mục chuẩn
  mkdir -p ${CA_DIR}/{certs,crl,newcerts,private}
  chmod 700 ${CA_DIR}/private
  touch ${CA_DIR}/index.txt
  echo 1000 > ${CA_DIR}/serial 
  echo 1000 > ${CA_DIR}/crlnumber  

  # TẠO FILE OPENSSL.CNF RIÊNG, LƯU VĨNH VIỄN TRONG THƯ MỤC CA
  cat > ${CA_DIR}/openssl.cnf << EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = .
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
private_key       = \$dir/private/ca.key
certificate       = \$dir/certs/ca.crt
default_days      = 365
default_crl_days  = 30
default_md        = sha256
policy            = policy_match

[ policy_match ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied

[ req ]
default_bits        = 2048
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name

[ req_distinguished_name ]
# Sẽ được ghi đè bởi cờ -subj

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_peer ]
basicConstraints = CA:FALSE
nsCertType = server
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth

[ v3_user ]
basicConstraints = CA:FALSE
nsCertType = client
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF

  # Tạo khóa riêng cho CA
  openssl ecparam -name prime256v1 -genkey -noout -out ${CA_DIR}/private/ca.key

  # Tạo chứng chỉ gốc, sử dụng file config và lưu vào thư mục /certs
  openssl req -x509 -new -nodes \
    -key ${CA_DIR}/private/ca.key \
    -sha256 -days 3650 \
    -out ${CA_DIR}/certs/ca.crt \
    -subj "/C=VN/ST=Hanoi/L=Hanoi/O=${ORG_NAME}/OU=Fabric/CN=ca.${ORG_DOMAIN}" \
    -config ${CA_DIR}/openssl.cnf \
    -extensions v3_ca
}


# --- HÀM MAIN ---
echo "--- XOÁ TẤT CẢ FILE CŨ ---"
rm -rf external-cas crypto-config config .env.msp
echo "✅ Đã dọn dẹp môi trường cũ."

# Tạo CA cho từng tổ chức
create_ca_structure "smartbanka" "smartbanka.com"
create_ca_structure "smartbankb" "smartbankb.com"
create_ca_structure "orderer" "example.com"

echo ""
echo "✅ HOÀN TẤT: Đã tạo xong hạ tầng CA đầy đủ cho 3 tổ chức!"