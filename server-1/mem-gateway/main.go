package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/openpcc/openpcc/gateway"
)

type seedSpec struct {
	KeyID       string `json:"key_id"`
	SeedHex     string `json:"seed_hex"`
	ActiveFrom  string `json:"active_from"`
	ActiveUntil string `json:"active_until"`
}

type seedEnvelope struct {
	OHTTPKeys  []seedSpec `json:"OHTTP_KEYS"`
	OHTTPSeeds []seedSpec `json:"ohttp_seeds"`
}

func main() {
	listenAddr := getenv("GATEWAY_LISTEN_ADDR", ":3200")
	bankURL := getenv("GATEWAY_BANK_URL", "http://localhost:3500")
	routerURL := getenv("GATEWAY_ROUTER_URL", "http://localhost:3600")
	seedsJSON := strings.TrimSpace(os.Getenv("OHTTP_SEEDS_JSON"))
	seedsRef := strings.TrimSpace(os.Getenv("OHTTP_SEEDS_SECRET_REF"))

	keys, usedEnv, err := loadKeysFromJSON(seedsJSON)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to parse OHTTP_SEEDS_JSON: %v\n", err)
		os.Exit(1)
	}
	if !usedEnv {
		if seedsRef != "" {
			fmt.Fprintln(os.Stderr, "OHTTP_SEEDS_SECRET_REF set but OHTTP_SEEDS_JSON empty")
			os.Exit(1)
		}
		defaultKey, err := defaultGatewayKey()
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to build default ohttp key: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintln(os.Stderr, "OHTTP_SEEDS_JSON not set; using default gateway seed")
		keys = []gateway.Key{defaultKey}
	}

	cfg := gateway.Config{
		Keys:      keys,
		BankURL:   bankURL,
		RouterURL: routerURL,
	}

	handler, err := gateway.NewGateway(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create gateway: %v\n", err)
		os.Exit(1)
	}

	// nosemgrep: go.lang.security.audit.net.use-tls.use-tls
	if err := http.ListenAndServe(listenAddr, handler); err != nil {
		fmt.Fprintf(os.Stderr, "gateway listen failed: %v\n", err)
		os.Exit(1)
	}
}

func loadKeysFromJSON(raw string) ([]gateway.Key, bool, error) {
	if raw == "" {
		return nil, false, nil
	}

	var seeds []seedSpec
	if err := json.Unmarshal([]byte(raw), &seeds); err == nil && len(seeds) > 0 {
		keys, err := toGatewayKeys(seeds)
		return keys, true, err
	}

	var envelope seedEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		return nil, true, err
	}
	switch {
	case len(envelope.OHTTPKeys) > 0:
		keys, err := toGatewayKeys(envelope.OHTTPKeys)
		return keys, true, err
	case len(envelope.OHTTPSeeds) > 0:
		keys, err := toGatewayKeys(envelope.OHTTPSeeds)
		return keys, true, err
	default:
		return nil, true, fmt.Errorf("no seeds found in OHTTP_SEEDS_JSON")
	}
}

func toGatewayKeys(seeds []seedSpec) ([]gateway.Key, error) {
	keys := make([]gateway.Key, 0, len(seeds))
	for idx, seed := range seeds {
		if strings.TrimSpace(seed.KeyID) == "" {
			return nil, fmt.Errorf("seed[%d].key_id is required", idx)
		}
		if strings.TrimSpace(seed.SeedHex) == "" {
			return nil, fmt.Errorf("seed[%d].seed_hex is required", idx)
		}
		if strings.TrimSpace(seed.ActiveFrom) == "" {
			return nil, fmt.Errorf("seed[%d].active_from is required", idx)
		}
		if strings.TrimSpace(seed.ActiveUntil) == "" {
			return nil, fmt.Errorf("seed[%d].active_until is required", idx)
		}

		keyID, err := parseKeyID(seed.KeyID)
		if err != nil {
			return nil, fmt.Errorf("seed[%d].key_id invalid: %w", idx, err)
		}
		activeFrom, err := time.Parse(time.RFC3339, seed.ActiveFrom)
		if err != nil {
			return nil, fmt.Errorf("seed[%d].active_from invalid: %w", idx, err)
		}
		activeUntil, err := time.Parse(time.RFC3339, seed.ActiveUntil)
		if err != nil {
			return nil, fmt.Errorf("seed[%d].active_until invalid: %w", idx, err)
		}

		keys = append(keys, gateway.Key{
			ID:          keyID,
			Seed:        seed.SeedHex,
			ActiveFrom:  activeFrom,
			ActiveUntil: activeUntil,
		})
	}
	return keys, nil
}

func parseKeyID(raw string) (byte, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return 0, fmt.Errorf("empty key_id")
	}
	base := 10
	trimmed := strings.TrimPrefix(value, "0x")
	if strings.HasPrefix(value, "0x") || hasHexAlpha(trimmed) {
		base = 16
	}
	parsed, err := strconv.ParseUint(trimmed, base, 8)
	if err != nil {
		return 0, err
	}
	return byte(parsed), nil
}

func hasHexAlpha(value string) bool {
	for _, r := range value {
		if (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			return true
		}
	}
	return false
}

func defaultGatewayKey() (gateway.Key, error) {
	activeFrom, err := time.Parse(time.RFC3339, "2025-09-18T18:00:13.132674Z")
	if err != nil {
		return gateway.Key{}, err
	}
	activeUntil, err := time.Parse(time.RFC3339, "2026-03-18T18:00:13.132674Z")
	if err != nil {
		return gateway.Key{}, err
	}
	return gateway.Key{
		ID:          1,
		Seed:        "0f4eda2e6c806018fb1082a6b0d8dc30c3aee556b41ac47cda7db81a57985997",
		ActiveFrom:  activeFrom,
		ActiveUntil: activeUntil,
	}, nil
}

func getenv(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}
