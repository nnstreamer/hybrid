package main

import (
	"errors"
	"fmt"
	"net/http"
	"slices"

	obhttp "github.com/openpcc/ohttp/encoding/bhttp"
	"github.com/openpcc/ohttp"
	"github.com/openpcc/openpcc/gateway"
	"github.com/openpcc/openpcc/messages"
)

func buildOHTTPClient(
	nonAnonClient *http.Client,
	relayURL string,
	keyConfigs ohttp.KeyConfigs,
	keyRotationPeriods []gateway.KeyRotationPeriodWithID,
) (*http.Client, error) {
	validKeys := slices.DeleteFunc(slices.Clone(keyRotationPeriods), func(m gateway.KeyRotationPeriodWithID) bool {
		return !m.IsActive()
	})
	if len(validKeys) == 0 {
		return nil, errors.New("no active OHTTP keys available")
	}

	desiredKey := slices.MaxFunc(validKeys, func(a, b gateway.KeyRotationPeriodWithID) int {
		return a.ActiveFrom.Compare(b.ActiveFrom)
	})
	desiredKeyConfigID := desiredKey.KeyID

	idx := slices.IndexFunc(keyConfigs, func(kc ohttp.KeyConfig) bool {
		return kc.KeyID == desiredKeyConfigID
	})
	if idx == -1 {
		return nil, fmt.Errorf("no key config found for key ID %d", desiredKeyConfigID)
	}
	desiredKeyConfig := keyConfigs[idx]

	reqEncoder, err := obhttp.NewRequestEncoder(
		obhttp.FixedLengthRequestChunks(),
		obhttp.MaxRequestChunkLen(messages.EncapsulatedChunkLen()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create ohttp request encoder: %w", err)
	}

	ohttpTransport, err := ohttp.NewTransport(
		desiredKeyConfig,
		relayURL,
		ohttp.WithHTTPClient(nonAnonClient),
		ohttp.WithRequestEncoder(reqEncoder),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create ohttp transport: %w", err)
	}

	return &http.Client{
		Timeout:   defaultHTTPClientTimeout,
		Transport: ohttpTransport,
	}, nil
}
