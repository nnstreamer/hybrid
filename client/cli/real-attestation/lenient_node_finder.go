package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"time"

	"github.com/openpcc/openpcc"
	"github.com/openpcc/openpcc/ahttp"
	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/attestation/verify"
	rtrpb "github.com/openpcc/openpcc/gen/protos/router"
	"github.com/openpcc/openpcc/httpfmt"
	"github.com/openpcc/openpcc/httpretry"
	"github.com/openpcc/openpcc/proton"
	"github.com/openpcc/openpcc/router/api"
	"github.com/openpcc/openpcc/tags"
	"google.golang.org/protobuf/proto"
)

type lenientNodeFinder struct {
	httpClient    *http.Client
	authClient    openpcc.AuthClient
	verifier      verify.Verifier
	routerBaseURL string
}

func newLenientNodeFinder(
	httpClient *http.Client,
	authClient openpcc.AuthClient,
	verifier verify.Verifier,
	routerBaseURL string,
) *lenientNodeFinder {
	return &lenientNodeFinder{
		httpClient:    httpClient,
		authClient:    authClient,
		verifier:      verifier,
		routerBaseURL: routerBaseURL,
	}
}

func (f *lenientNodeFinder) FindVerifiedNodes(ctx context.Context, maxNodes int, tagslist tags.Tags) ([]openpcc.VerifiedNode, error) {
	attestationToken, err := f.authClient.GetAttestationToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get attestation token: %w", err)
	}

	query := &rtrpb.ComputeManifestRequest{}
	limit, ok := safeInt32(maxNodes)
	if !ok {
		return nil, fmt.Errorf("expected max nodes to fit in int32, got %d", maxNodes)
	}
	query.SetLimit(limit)
	query.SetTags(tagslist.Slice())
	data, err := proto.Marshal(query)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal compute manifest query: %w", err)
	}

	routerReq, err := http.NewRequestWithContext(ctx, http.MethodPost, f.routerBaseURL+"/compute-manifests", bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("failed to create compute manifest request: %w", err)
	}
	routerReq.Header.Set("Content-Type", "application/octet-stream")

	creditHeader, err := encodeCreditHeader(attestationToken)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal attestation token: %w", err)
	}
	routerReq.Header.Set(ahttp.CreditHeader, creditHeader)

	routerResp, err := httpretry.Do(f.httpClient, routerReq)
	if err != nil {
		return nil, fmt.Errorf("failed to request compute manifests: %w", err)
	}
	defer routerResp.Body.Close()

	if routerResp.StatusCode != http.StatusOK {
		err = fmt.Errorf("unexpected status code %d", routerResp.StatusCode)
		return nil, httpfmt.ParseBodyAsError(routerResp, err)
	}

	manifestList := &rtrpb.ComputeManifestList{}
	if err := proton.NewDecoder(routerResp.Body).Decode(manifestList); err != nil {
		return nil, fmt.Errorf("failed to decode evidence list: %w", err)
	}

	items := manifestList.GetItems()
	nodes := make([]openpcc.VerifiedNode, 0, len(items))
	for _, item := range items {
		var manifest api.ComputeManifest
		if err := manifest.UnmarshalProto(item); err != nil {
			continue
		}
		nodeID := manifest.ID.String()
		verifiedData, err := f.verifier.VerifyComputeNode(ctx, manifest.Evidence)
		if err != nil {
			nitroErr := verifyNitroEvidence(manifest.Evidence)
			if nitroErr != nil {
				printAttestationWarning(nodeID, fmt.Errorf("%v; nitro=%v", err, nitroErr))
			}
			verifiedData, err = unsafeComputeDataFromEvidence(manifest.Evidence)
			if err != nil {
				continue
			}
		}

		nodes = append(nodes, openpcc.VerifiedNode{
			Manifest:    manifest,
			TrustedData: *verifiedData,
			VerifiedAt:  time.Now(),
		})
	}

	return nodes, nil
}

func (*lenientNodeFinder) ListCachedVerifiedNodes() ([]openpcc.VerifiedNode, error) {
	return nil, nil
}

func encodeCreditHeader(credit *anonpay.BlindedCredit) (string, error) {
	creditProto, err := credit.MarshalProto()
	if err != nil {
		return "", fmt.Errorf("failed to marshal credit: %w", err)
	}
	creditBytes, err := proto.Marshal(creditProto)
	if err != nil {
		return "", fmt.Errorf("failed to marshal credit: %w", err)
	}
	creditB64 := base64.StdEncoding.EncodeToString(creditBytes)
	return creditB64, nil
}

func safeInt32(v int) (int32, bool) {
	if v < -2147483648 || v > 2147483647 {
		return 0, false
	}
	return int32(v), true
}
