package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/openpcc/ohttp"
	"github.com/openpcc/openpcc/gateway"
)

func TestParseOHTTPKeyBundleSuccess(t *testing.T) {
	kemID, _, _ := gateway.Suite.Params()
	seed := make([]byte, kemID.Scheme().SeedSize())
	seed[0] = 0x01
	bundle := server3OHTTPKeyBundle{
		Format: server3KeyBundleFormat,
		Keys: []server3OHTTPKeyEntry{
			{
				KeyID:           "01",
				PublicKeyB64:    base64.StdEncoding.EncodeToString(seed),
				PublicKeyFormat: publicKeyFormatSHA256,
			},
		},
	}
	bundleJSON, err := json.Marshal(bundle)
	if err != nil {
		t.Fatalf("failed to marshal bundle JSON: %v", err)
	}
	bundleB64 := base64.StdEncoding.EncodeToString(bundleJSON)

	keyConfigs, err := parseOHTTPKeyBundle(bundleB64)
	if err != nil {
		t.Fatalf("expected success, got error: %v", err)
	}
	if len(keyConfigs) != 1 {
		t.Fatalf("expected 1 key config, got %d", len(keyConfigs))
	}
	if keyConfigs[0].KeyID != 1 {
		t.Fatalf("expected key ID 1, got %d", keyConfigs[0].KeyID)
	}
	expectedPub, _ := kemID.Scheme().DeriveKeyPair(seed)
	expectedBytes, err := expectedPub.MarshalBinary()
	if err != nil {
		t.Fatalf("failed to marshal expected public key: %v", err)
	}
	actualBytes, err := keyConfigs[0].PublicKey.MarshalBinary()
	if err != nil {
		t.Fatalf("failed to marshal actual public key: %v", err)
	}
	if !bytes.Equal(actualBytes, expectedBytes) {
		t.Fatalf("unexpected public key bytes")
	}
}

func TestParseOHTTPRotationPeriodsSuccess(t *testing.T) {
	periods := []server3OHTTPRotationPeriod{
		{
			KeyID:       "01",
			ActiveFrom:  "2026-01-30T00:00:00Z",
			ActiveUntil: "2026-02-01T00:00:00Z",
		},
	}

	rotation, err := parseOHTTPRotationPeriods(periods)
	if err != nil {
		t.Fatalf("expected success, got error: %v", err)
	}
	if len(rotation) != 1 {
		t.Fatalf("expected 1 rotation period, got %d", len(rotation))
	}
	if rotation[0].KeyID != 1 {
		t.Fatalf("expected key ID 1, got %d", rotation[0].KeyID)
	}
}

func TestValidateOHTTPRotationKeysMissing(t *testing.T) {
	kemID, _, _ := gateway.Suite.Params()
	seed := make([]byte, kemID.Scheme().SeedSize())
	seed[0] = 0x02
	publicKey, _ := kemID.Scheme().DeriveKeyPair(seed)
	keyConfigs := ohttp.KeyConfigs{
		{
			KeyID:     1,
			PublicKey: publicKey,
		},
	}
	rotation := []gateway.KeyRotationPeriodWithID{
		{KeyID: 2},
	}

	if err := validateOHTTPRotationKeys(keyConfigs, rotation); err == nil {
		t.Fatalf("expected error for missing key ID")
	}
}
