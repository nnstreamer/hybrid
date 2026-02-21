package main

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/cloudflare/circl/hpke"
	"github.com/fxamacker/cbor/v2"
	"github.com/google/go-tpm/tpm2"
	ev "github.com/openpcc/openpcc/attestation/evidence"
	tpmhpke "github.com/openpcc/openpcc/tpm/hpke"
)

const warningWidth = 60

func verifyNitroEvidence(evidence ev.SignedEvidenceList) error {
	nitroPiece := findEvidencePiece(ev.SevSnpExtendedReport, evidence)
	if nitroPiece == nil {
		return errors.New("nitro attestation evidence missing")
	}
	tpmQuote := findEvidencePiece(ev.TpmQuote, evidence)
	if tpmQuote == nil {
		return errors.New("no tpm quote provided")
	}
	tpmQuoteHash := sha256.Sum256(tpmQuote.Signature)
	teeNonce, err := ev.PadByteArrayTo64(tpmQuoteHash[:])
	if err != nil {
		return fmt.Errorf("failed to pad tpm quote hash: %w", err)
	}
	nitroNonce, err := parseNitroAttestationNonce(nitroPiece.Data)
	if err != nil {
		return fmt.Errorf("failed to parse nitro attestation document: %w", err)
	}
	if !bytes.Equal(nitroNonce, teeNonce) {
		return errors.New("nitro attestation nonce mismatch")
	}
	return nil
}

func parseNitroAttestationNonce(doc []byte) ([]byte, error) {
	if len(doc) == 0 {
		return nil, errors.New("nitro attestation document empty")
	}
	var cose []any
	if err := cbor.Unmarshal(doc, &cose); err != nil {
		return nil, fmt.Errorf("failed to decode COSE_Sign1: %w", err)
	}
	if len(cose) != 4 {
		return nil, fmt.Errorf("unexpected COSE_Sign1 length %d", len(cose))
	}
	payloadBytes, ok := cose[2].([]byte)
	if !ok || len(payloadBytes) == 0 {
		return nil, errors.New("cose payload missing")
	}
	var payload struct {
		Nonce []byte `cbor:"nonce"`
	}
	if err := cbor.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, fmt.Errorf("failed to decode attestation payload: %w", err)
	}
	if len(payload.Nonce) == 0 {
		return nil, errors.New("nitro nonce missing")
	}
	return payload.Nonce, nil
}

func unsafeComputeDataFromEvidence(evidence ev.SignedEvidenceList) (*ev.ComputeData, error) {
	tpmtPublicEvidence := findEvidencePiece(ev.TpmtPublic, evidence)
	if tpmtPublicEvidence == nil {
		return nil, errors.New("failed to find tpmt public evidence")
	}
	tpmtPublic, err := tpm2.Unmarshal[tpm2.TPMTPublic](tpmtPublicEvidence.Data)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal TPMT public key: %w", err)
	}
	rekECCPublicKey, err := tpmhpke.Pub(tpmtPublic)
	if err != nil {
		return nil, fmt.Errorf("failed to cast rek public key to ECC: %w", err)
	}
	nodePubKeyB, err := rekECCPublicKey.MarshalBinary()
	if err != nil {
		return nil, fmt.Errorf("failed to marshal public key to bytes: %w", err)
	}
	return &ev.ComputeData{
		KEM:       hpke.KEM_P256_HKDF_SHA256,
		KDF:       hpke.KDF_HKDF_SHA256,
		AEAD:      hpke.AEAD_AES128GCM,
		PublicKey: nodePubKeyB,
	}, nil
}

func findEvidencePiece(evidenceType ev.EvidenceType, evidence ev.SignedEvidenceList) *ev.SignedEvidencePiece {
	for _, piece := range evidence {
		if piece.Type == evidenceType {
			return piece
		}
	}
	return nil
}

func printAttestationWarning(nodeID string, err error) {
	if err == nil {
		err = errors.New("unknown error")
	}
	line := strings.Repeat("*", warningWidth)
	fmt.Fprintln(os.Stderr, line)
	fmt.Fprintln(os.Stderr, warningLine("REAL ATTEST WARNING"))
	fmt.Fprintln(os.Stderr, warningLine("node_id="+nodeID))
	fmt.Fprintln(os.Stderr, warningLine("verify failed: "+err.Error()))
	fmt.Fprintln(os.Stderr, line)
}

func warningLine(message string) string {
	innerWidth := warningWidth - 4
	if innerWidth < 1 {
		return "**"
	}
	if len(message) > innerWidth {
		message = message[:innerWidth]
	}
	return "* " + message + strings.Repeat(" ", innerWidth-len(message)) + " *"
}
