package main

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"sync"

	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/anonpay/currency"
)

// Test key used for local/dev credits (matches upstream test utilities).
const currencyPrivateKeyPEMBase64 = `LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlDWGdJQkFBS0JnUURodmNVN1M4UkRa
aHhBTldzQmJVQ0tTUzRXb0dQL3NXL2h3TGJSR3dkNzk2MFlpRmR3CjBpdUtOWDJwaHlyR2dHNW1l
alhWMFF3UmthRVNTZEtjTzAzTFFTUzR5YURYekQ0WjJQRng2SW9rMDIyYk1sbXoKNFF6MHB0UUFH
ZmVBS1I4NVJzZzlWaUp1Z2NybGRUWmJsZjBCd1h0ZTB3c2RtbFBGNHdNTzVSUk1kUUlEQVFBQgpB
b0dCQUsyajFwR2MzelBrMkhnL1hyYnpQY0RoTjVWcC9HR1RML2RiMElRYUlYQ20vRHV4ckdqNUVV
cTNpSmlkCmd6YTdWYkIzOHU4c1pQY2lxTjR6Y05DQ0FYeVVHSmFrNitQQ0dDc2NPK09KbkEvc0Vt
a0dkS0NJUHpXS3VwRm4KMDgxNVdmMTB2L3ZDT1FuNit0eGZoQ2ZLRFBJRzRNdGFwajZSQndEemRE
YnZaOENsQWtFQTlDM0ZkdFV2WHAzbQo0cGpUVUwxbHBxVVYzTWhNaStUWWhRSGFPTyt0cmtkeTll
U0tSTDAxK0phMVhEejd4TnZQZVovOW1iR0s0MjN2CkRGYXpSSVVQaXdKQkFPeXJmblhCc2kyMkVm
RUEvRFZHQTBuMkZSeE1FMG5ESzZMbmovSlNLcFR0Y2M5ZHhKNEwKTjhZc21XTmlGTkNwOERBbHdU
ZFBlMFJKNzlUWUlXbDNrLzhDUVFDQ3NiVU5nOUhVN09OVnljTGhabDV3TWRCZgoyZjNPcXZDUlVJ
cURDeGFGUDh6eWZCN2Q2QUJwVEJGS2k0R2V2cUJ3VXdna0tYbFRmZFlEWHF5Wk1qYzlBa0FTCm40
Z0s4aHY0TnR5QWoyaEpOT0lyWHI3WWhDLzhYT3hCSEdHYVd0Ylk4enBDYkFsOXVqcEFVT0FkRHVt
K1piRHQKeVByRVJHL1p0c3UxZnZCYUlUdTNBa0VBd3dsbHltQ250Wm9iejdxR1RNc29CaUFEeW52
ZHVCRkx0QUE0OVVZMApvek1vVkhzN3BGMjBKb0J0QU93dFkzWWJXYzNXRmpqUGQrRU0yU3JBVnZZ
cjR3PT0KLS0tLS1FTkQgUlNBIFBSSVZBVEUgS0VZLS0tLS0K`

var (
	testKeyOnce sync.Once
	testKey     *rsa.PrivateKey
	testKeyErr  error
)

func currencyPrivateKey() (*rsa.PrivateKey, error) {
	testKeyOnce.Do(func() {
		testKey, testKeyErr = parsePrivateKey(currencyPrivateKeyPEMBase64)
	})
	return testKey, testKeyErr
}

func newTestIssuer() (*anonpay.Issuer, error) {
	key, err := currencyPrivateKey()
	if err != nil {
		return nil, err
	}
	return anonpay.NewIssuer(key)
}

func newTestPayee() (*anonpay.Payee, error) {
	key, err := currencyPrivateKey()
	if err != nil {
		return nil, err
	}
	return anonpay.NewPayee(&key.PublicKey), nil
}

func blindCredit(ctx context.Context, val currency.Value) (*anonpay.BlindedCredit, error) {
	issuer, err := newTestIssuer()
	if err != nil {
		return nil, err
	}
	payee, err := newTestPayee()
	if err != nil {
		return nil, err
	}
	unsignedCredit, err := payee.BeginBlindedCredit(ctx, val)
	if err != nil {
		return nil, err
	}
	blindSignature, err := issuer.BlindSign(ctx, unsignedCredit.Request())
	if err != nil {
		return nil, err
	}
	return unsignedCredit.Finalize(blindSignature)
}

func parsePrivateKey(b64Val string) (*rsa.PrivateKey, error) {
	pemStr, err := base64.StdEncoding.DecodeString(b64Val)
	if err != nil {
		return nil, fmt.Errorf("failed to base64 decode currency test key: %w", err)
	}
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, errors.New("failed to decode PEM block")
	}
	privKey, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}
	return privKey, nil
}
