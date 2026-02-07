package main

import (
	"crypto/sha256"
	"testing"

	"github.com/fxamacker/cbor/v2"
	ev "github.com/openpcc/openpcc/attestation/evidence"
)

func buildNitroDoc(t *testing.T, nonce []byte) []byte {
	t.Helper()
	payload := struct {
		Nonce []byte `cbor:"nonce"`
	}{
		Nonce: nonce,
	}
	payloadBytes, err := cbor.Marshal(payload)
	if err != nil {
		t.Fatalf("failed to marshal payload: %v", err)
	}
	cose := []any{
		[]byte{0x01},
		map[any]any{},
		payloadBytes,
		[]byte{0x02},
	}
	doc, err := cbor.Marshal(cose)
	if err != nil {
		t.Fatalf("failed to marshal cose: %v", err)
	}
	return doc
}

func TestParseNitroAttestationNonceSuccess(t *testing.T) {
	nonce := []byte("nonce-data")
	doc := buildNitroDoc(t, nonce)

	got, err := parseNitroAttestationNonce(doc)
	if err != nil {
		t.Fatalf("expected success, got error: %v", err)
	}
	if string(got) != string(nonce) {
		t.Fatalf("unexpected nonce: got %q want %q", string(got), string(nonce))
	}
}

func TestParseNitroAttestationNonceBadDocument(t *testing.T) {
	if _, err := parseNitroAttestationNonce(nil); err == nil {
		t.Fatalf("expected error for empty document")
	}

	doc, err := cbor.Marshal([]any{[]byte{0x01}})
	if err != nil {
		t.Fatalf("failed to marshal short cose: %v", err)
	}
	if _, err := parseNitroAttestationNonce(doc); err == nil {
		t.Fatalf("expected error for invalid cose length")
	}
}

func TestVerifyNitroEvidenceSuccess(t *testing.T) {
	sig := []byte("tpm-quote-signature")
	hash := sha256.Sum256(sig)
	nonce, err := ev.PadByteArrayTo64(hash[:])
	if err != nil {
		t.Fatalf("failed to pad nonce: %v", err)
	}
	doc := buildNitroDoc(t, nonce)

	evidence := ev.SignedEvidenceList{
		&ev.SignedEvidencePiece{
			Type: ev.SevSnpExtendedReport,
			Data: doc,
		},
		&ev.SignedEvidencePiece{
			Type:      ev.TpmQuote,
			Signature: sig,
		},
	}

	if err := verifyNitroEvidence(evidence); err != nil {
		t.Fatalf("expected success, got error: %v", err)
	}
}

func TestVerifyNitroEvidenceMismatch(t *testing.T) {
	sig := []byte("tpm-quote-signature")
	hash := sha256.Sum256(sig)
	nonce, err := ev.PadByteArrayTo64(hash[:])
	if err != nil {
		t.Fatalf("failed to pad nonce: %v", err)
	}
	nonce[0] ^= 0xff
	doc := buildNitroDoc(t, nonce)

	evidence := ev.SignedEvidenceList{
		&ev.SignedEvidencePiece{
			Type: ev.SevSnpExtendedReport,
			Data: doc,
		},
		&ev.SignedEvidencePiece{
			Type:      ev.TpmQuote,
			Signature: sig,
		},
	}

	if err := verifyNitroEvidence(evidence); err == nil {
		t.Fatalf("expected error for nonce mismatch")
	}
}
