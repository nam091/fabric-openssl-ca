#!/bin/bash
# =================================================================
# == KỊCH BẢN TẠO MÃ NGUỒN VÀ DEPENDENCIES CHO CHAINCODE         ==
# =================================================================
set -e

sudo rm -rf chaincode/bank

# Tạo cấu trúc thư mục
mkdir -p chaincode/bank

cat > chaincode/bank/bank.go << 'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

type SmartContract struct {
	contractapi.Contract
}

// Cấu trúc Account đã được thêm trường Status
type Account struct {
	Balance float64 `json:"balance"`
	Status  string  `json:"status"` // Trạng thái: "ACTIVE" hoặc "REVOKED"
}

// Hàm InitLedger để khởi tạo dữ liệu mẫu
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	accounts := []struct {
		ID      string
		Balance float64
	}{
		{"user1@smartbanka.com", 100000000},
		{"user2@smartbanka.com", 150000000},
		{"user1@smartbankb.com", 200000000},
		{"user2@smartbankb.com", 250000000},
	}

	fmt.Println("--- Initializing Ledger with sample accounts ---")

	for _, account := range accounts {
		err := s.CreateAccount(ctx, account.ID, account.Balance)
		if err != nil {
			fmt.Printf("Could not create account %s: %s. It might already exist.\n", account.ID, err.Error())
		}
	}
	return nil
}

// Tài khoản mới tạo sẽ có trạng thái "ACTIVE"
func (s *SmartContract) CreateAccount(ctx contractapi.TransactionContextInterface, accountID string, initialBalance float64) error {
	accountJSON, err := ctx.GetStub().GetState(accountID)
	if err != nil {
		return fmt.Errorf("failed to read from world state: %v", err)
	}
	if accountJSON != nil {
		return fmt.Errorf("the account %s already exists", accountID)
	}
	account := Account{
		Balance: initialBalance,
		Status:  "ACTIVE",
	}
	accountBytes, _ := json.Marshal(account)
	return ctx.GetStub().PutState(accountID, accountBytes)
}

// Hàm Query sẽ kiểm tra trạng thái tài khoản trước khi trả về
func (s *SmartContract) Query(ctx contractapi.TransactionContextInterface, accountID string) (*Account, error) {
	accountJSON, err := ctx.GetStub().GetState(accountID)
	if err != nil {
		return nil, fmt.Errorf("failed to read from world state: %v", err)
	}
	if accountJSON == nil {
		return nil, fmt.Errorf("the account %s does not exist", accountID)
	}
	var account Account
	err = json.Unmarshal(accountJSON, &account)
	if err != nil {
		return nil, err
	}
	if account.Status == "REVOKED" {
		return nil, fmt.Errorf("account %s has been revoked", accountID)
	}
	return &account, nil
}

// Hàm Transfer sẽ kiểm tra trạng thái của cả 2 tài khoản
func (s *SmartContract) Transfer(ctx contractapi.TransactionContextInterface, fromID string, toID string, amount float64) error {
	fromAccount, err := s.Query(ctx, fromID)
	if err != nil {
		return err
	}
	toAccount, err := s.Query(ctx, toID)
	if err != nil {
		return err
	}
	if fromAccount.Balance < amount {
		return fmt.Errorf("account %s has insufficient funds", fromID)
	}
	fromAccount.Balance -= amount
	toAccount.Balance += amount

	fromAccountBytes, _ := json.Marshal(fromAccount)
	toAccountBytes, _ := json.Marshal(toAccount)

	ctx.GetStub().PutState(fromID, fromAccountBytes)
	ctx.GetStub().PutState(toID, toAccountBytes)

	return nil
}

// Hàm mới để thu hồi tài khoản
func (s *SmartContract) RevokeAccount(ctx contractapi.TransactionContextInterface, accountID string) error {
	accountJSON, err := ctx.GetStub().GetState(accountID)
	if err != nil {
		return fmt.Errorf("failed to read from world state: %v", err)
	}
	if accountJSON == nil {
		return fmt.Errorf("the account %s does not exist", accountID)
	}
	var account Account
	json.Unmarshal(accountJSON, &account)

	account.Status = "REVOKED"

	accountBytes, _ := json.Marshal(account)
	return ctx.GetStub().PutState(accountID, accountBytes)
}

func (s *SmartContract) ReactivateAccount(ctx contractapi.TransactionContextInterface, accountID string) error {
    accountJSON, err := ctx.GetStub().GetState(accountID)
	if err != nil {
		return fmt.Errorf("failed to read from world state: %v", err)
	}
	if accountJSON == nil {
		return fmt.Errorf("the account %s does not exist", accountID)
	}
	var account Account
	json.Unmarshal(accountJSON, &account)

    if account.Status != "REVOKED" {
        return fmt.Errorf("account %s is not in revoked state", accountID)
    }

    // Đổi trạng thái lại thành ACTIVE
	account.Status = "ACTIVE"

	accountBytes, _ := json.Marshal(account)
	return ctx.GetStub().PutState(accountID, accountBytes)
}

func main() {
	chaincode, err := contractapi.NewChaincode(new(SmartContract))
	if err != nil {
		fmt.Printf("Error creating bank chaincode: %s", err.Error())
		return
	}
	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting bank chaincode: %s", err.Error())
	}
}
EOF

# Tạo file go.mod với cú pháp 'EOF'
cat > chaincode/bank/go.mod << 'EOF'
module bank

go 1.18

require github.com/hyperledger/fabric-contract-api-go v1.2.1
EOF

# Chạy go mod tidy để tạo go.sum, sau đó mới vendor
cd chaincode/bank
echo "--- Tidying and Vending Go modules ---"
go mod tidy
go mod vendor
cd ../..

echo "✅ Chaincode generation complete with RevokeAccount + ReactivateAccount + CreateAccount + Query + Transfer function!"