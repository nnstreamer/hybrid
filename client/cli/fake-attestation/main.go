package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/openpcc/ohttp"
	"github.com/openpcc/openpcc"
	"github.com/openpcc/openpcc/ahttp"
	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/anonpay/currency"
	"github.com/openpcc/openpcc/anonpay/wallet"
	authclient "github.com/openpcc/openpcc/auth/client"
	"github.com/openpcc/openpcc/auth/credentialing"
	"github.com/openpcc/openpcc/gateway"
	"github.com/openpcc/openpcc/inttest"
	"github.com/openpcc/openpcc/keyrotation"
)

const (
	configPath           = "/etc/nnstreamer/hybrid.ini"
	defaultRouterURL     = "http://localhost:3600"
	defaultModel         = "llama3.2:1b"
	defaultPrompt        = "Hello from OpenPCC."
	defaultFakeSecret    = "123456"
	envRouterURL         = "ROUTER_URL"
	envAltRouterURL      = "OPENPCC_ROUTER_URL"
	envRelayURL          = "RELAY_URL"
	envAltRelayURL       = "OPENPCC_RELAY_URL"
	envOHTTPSeedsJSON    = "OHTTP_SEEDS_JSON"
	envAltOHTTPSeedsJSON = "OPENPCC_OHTTP_SEEDS_JSON"
	envModelName         = "MODEL_NAME"
	envPromptText        = "PROMPT_TEXT"
	envFakeSecret        = "FAKE_ATTESTATION_SECRET"
	routerURLConfigKey   = "router_url"
	relayURLConfigKey    = "relay_url"
	ohttpSeedsJSONKey    = "ohttp_seeds_json"
)

type fakeAuthClient struct {
	badge        credentialing.Badge
	remoteConfig authclient.RemoteConfig
}

func (f fakeAuthClient) RemoteConfig() authclient.RemoteConfig {
	return f.remoteConfig
}

func (f fakeAuthClient) GetAttestationToken(ctx context.Context) (*anonpay.BlindedCredit, error) {
	credit, err := blindCredit(ctx, ahttp.AttestationCurrencyValue)
	if err != nil {
		return nil, err
	}
	return credit, nil
}

func (f fakeAuthClient) GetCredit(ctx context.Context, amountNeeded int64) (*anonpay.BlindedCredit, error) {
	val, err := currency.Rounded(float64(amountNeeded), 1.0)
	if err != nil {
		return nil, err
	}
	credit, err := blindCredit(ctx, val)
	if err != nil {
		return nil, err
	}
	return credit, nil
}

func (f fakeAuthClient) PutCredit(ctx context.Context, _ *anonpay.BlindedCredit) error {
	return nil
}

func (f fakeAuthClient) GetBadge(ctx context.Context) (credentialing.Badge, error) {
	return f.badge, nil
}

func (f fakeAuthClient) Payee() *anonpay.Payee {
	payee, err := newTestPayee()
	if err != nil {
		panic(err)
	}
	return payee
}

type fixedPayment struct {
	credit *anonpay.BlindedCredit
}

func (p *fixedPayment) Success(_ *anonpay.UnblindedCredit) error { return nil }
func (p *fixedPayment) Credit() *anonpay.BlindedCredit           { return p.credit }
func (p *fixedPayment) Cancel() error                            { return nil }

type fixedWallet struct{}

func (w *fixedWallet) BeginPayment(ctx context.Context, amount int64) (wallet.Payment, error) {
	val, err := currency.Rounded(float64(amount), 1.0)
	if err != nil {
		return nil, err
	}
	credit, err := blindCredit(ctx, val)
	if err != nil {
		return nil, err
	}
	return &fixedPayment{credit: credit}, nil
}

func (w *fixedWallet) Status() wallet.Status                { return wallet.Status{} }
func (w *fixedWallet) SetDefaultCreditAmount(_ int64) error { return nil }
func (w *fixedWallet) Close(_ context.Context) error        { return nil }

func makeBadge(model string) (credentialing.Badge, error) {
	badgeKey, err := inttest.NewTestBadgeKeyProvider().PrivateKey()
	if err != nil {
		return credentialing.Badge{}, err
	}
	creds := credentialing.Credentials{Models: []string{model}}
	credBytes, err := creds.MarshalBinary()
	if err != nil {
		return credentialing.Badge{}, err
	}
	sig := ed25519.Sign(badgeKey, credBytes)
	return credentialing.Badge{Credentials: creds, Signature: sig}, nil
}

type ohttpSeedSpec struct {
	KeyID       string `json:"key_id"`
	SeedHex     string `json:"seed_hex"`
	ActiveFrom  string `json:"active_from"`
	ActiveUntil string `json:"active_until"`
}

type ohttpSeedsEnvelope struct {
	OHTTPKeys  []ohttpSeedSpec `json:"OHTTP_KEYS"`
	OHTTPSeeds []ohttpSeedSpec `json:"ohttp_seeds"`
}

func parseOHTTPFlag(args []string) (bool, error) {
	raw, found, err := findOHTTPFlag(args)
	if err != nil {
		return false, err
	}
	if !found {
		return false, fmt.Errorf("missing required option: -ohttp=enable|disable (also accepts 1/0, t/f)")
	}
	return parseOHTTPValue(raw)
}

func findOHTTPFlag(args []string) (string, bool, error) {
	for idx := 1; idx < len(args); idx++ {
		arg := strings.TrimSpace(args[idx])
		if strings.HasPrefix(arg, "-ohttp=") {
			return strings.TrimPrefix(arg, "-ohttp="), true, nil
		}
		if strings.HasPrefix(arg, "--ohttp=") {
			return strings.TrimPrefix(arg, "--ohttp="), true, nil
		}
		if arg == "-ohttp" || arg == "--ohttp" {
			if idx+1 >= len(args) {
				return "", true, fmt.Errorf("missing value for -ohttp (use enable/disable or 1/0, t/f)")
			}
			return args[idx+1], true, nil
		}
	}
	return "", false, nil
}

func parseOHTTPValue(raw string) (bool, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "enable", "enabled", "1", "t", "true":
		return true, nil
	case "disable", "disabled", "0", "f", "false":
		return false, nil
	default:
		return false, fmt.Errorf("invalid -ohttp value %q (use enable/disable or 1/0, t/f)", raw)
	}
}

func parseOHTTPSeedsJSON(raw string) ([]ohttpSeedSpec, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("OHTTP seeds JSON is empty")
	}

	var seeds []ohttpSeedSpec
	if err := json.Unmarshal([]byte(raw), &seeds); err == nil && len(seeds) > 0 {
		return seeds, nil
	}

	var envelope ohttpSeedsEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		return nil, err
	}
	switch {
	case len(envelope.OHTTPKeys) > 0:
		return envelope.OHTTPKeys, nil
	case len(envelope.OHTTPSeeds) > 0:
		return envelope.OHTTPSeeds, nil
	default:
		return nil, fmt.Errorf("no ohttp seeds found in JSON")
	}
}

func buildOHTTPKeyMaterial(seeds []ohttpSeedSpec) (ohttp.KeyConfigs, []gateway.KeyRotationPeriodWithID, error) {
	if len(seeds) == 0 {
		return nil, nil, fmt.Errorf("no ohttp seeds provided")
	}
	kemID, kdfID, aeadID := gateway.Suite.Params()
	keyConfigs := make(ohttp.KeyConfigs, 0, len(seeds))
	rotationPeriods := make([]gateway.KeyRotationPeriodWithID, 0, len(seeds))

	for idx, seed := range seeds {
		if strings.TrimSpace(seed.KeyID) == "" {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].key_id is required", idx)
		}
		if strings.TrimSpace(seed.SeedHex) == "" {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].seed_hex is required", idx)
		}
		if strings.TrimSpace(seed.ActiveFrom) == "" {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].active_from is required", idx)
		}
		if strings.TrimSpace(seed.ActiveUntil) == "" {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].active_until is required", idx)
		}

		keyID, err := parseKeyID(seed.KeyID)
		if err != nil {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].key_id invalid: %w", idx, err)
		}
		seedBytes, err := hex.DecodeString(strings.TrimSpace(seed.SeedHex))
		if err != nil {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].seed_hex invalid: %w", idx, err)
		}
		activeFrom, err := time.Parse(time.RFC3339, seed.ActiveFrom)
		if err != nil {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].active_from invalid: %w", idx, err)
		}
		activeUntil, err := time.Parse(time.RFC3339, seed.ActiveUntil)
		if err != nil {
			return nil, nil, fmt.Errorf("ohttp_seeds[%d].active_until invalid: %w", idx, err)
		}

		pubKey, _ := kemID.Scheme().DeriveKeyPair(seedBytes)
		keyConfigs = append(keyConfigs, ohttp.KeyConfig{
			KeyID:     keyID,
			KemID:     kemID,
			PublicKey: pubKey,
			SymmetricAlgorithms: []ohttp.SymmetricAlgorithm{
				{
					KDFID:  kdfID,
					AEADID: aeadID,
				},
			},
		})
		rotationPeriods = append(rotationPeriods, gateway.KeyRotationPeriodWithID{
			Period: keyrotation.Period{
				ActiveFrom:  activeFrom,
				ActiveUntil: activeUntil,
			},
			KeyID: keyID,
		})
	}

	return keyConfigs, rotationPeriods, nil
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

func resolveRouterURL() (string, string, error) {
	if value := strings.TrimSpace(os.Getenv(envAltRouterURL)); value != "" {
		return normalizeURL(value), "env", nil
	}
	if value := strings.TrimSpace(os.Getenv(envRouterURL)); value != "" {
		return normalizeURL(value), "env", nil
	}

	value, err := routerURLFromConfig(configPath)
	if err != nil {
		return "", "", err
	}
	if value != "" {
		return normalizeURL(value), "config", nil
	}

	return defaultRouterURL, "default", nil
}

func resolveRelayURL() (string, string, error) {
	if value := strings.TrimSpace(os.Getenv(envAltRelayURL)); value != "" {
		return normalizeURL(value), "env", nil
	}
	if value := strings.TrimSpace(os.Getenv(envRelayURL)); value != "" {
		return normalizeURL(value), "env", nil
	}

	value, err := relayURLFromConfig(configPath)
	if err != nil {
		return "", "", err
	}
	if value != "" {
		return normalizeURL(value), "config", nil
	}

	return "", "", fmt.Errorf(
		"missing relay URL (set %s/%s or %s in %s)",
		envRelayURL,
		envAltRelayURL,
		relayURLConfigKey,
		configPath,
	)
}

func resolveOHTTPSeedsJSON() (string, string, error) {
	if value := strings.TrimSpace(os.Getenv(envAltOHTTPSeedsJSON)); value != "" {
		return value, "env", nil
	}
	if value := strings.TrimSpace(os.Getenv(envOHTTPSeedsJSON)); value != "" {
		return value, "env", nil
	}

	value, err := ohttpSeedsJSONFromConfig(configPath)
	if err != nil {
		return "", "", err
	}
	if value != "" {
		return value, "config", nil
	}

	return "", "", fmt.Errorf(
		"missing OHTTP seeds JSON (set %s/%s or %s in %s)",
		envOHTTPSeedsJSON,
		envAltOHTTPSeedsJSON,
		ohttpSeedsJSONKey,
		configPath,
	)
}

func routerURLFromConfig(path string) (string, error) {
	return configValueFromFile(path, routerURLConfigKey, "server1_url", "server_1_url")
}

func relayURLFromConfig(path string) (string, error) {
	return configValueFromFile(path, relayURLConfigKey)
}

func ohttpSeedsJSONFromConfig(path string) (string, error) {
	return configValueFromFile(path, ohttpSeedsJSONKey)
}

func configValueFromFile(path string, keys ...string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	defer file.Close()

	keySet := map[string]struct{}{}
	for _, key := range keys {
		keySet[strings.ToLower(key)] = struct{}{}
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			continue
		}
		key, value, ok := splitKeyValue(line)
		if !ok {
			continue
		}
		key = strings.ToLower(key)
		if _, ok := keySet[key]; !ok {
			continue
		}
		value = stripInlineComment(value)
		value = strings.TrimSpace(strings.Trim(value, `"'`))
		if value != "" {
			return value, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", nil
}

func splitKeyValue(line string) (string, string, bool) {
	parts := strings.SplitN(line, "=", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	key := strings.TrimSpace(parts[0])
	value := strings.TrimSpace(parts[1])
	if key == "" || value == "" {
		return "", "", false
	}
	return key, value, true
}

func stripInlineComment(value string) string {
	if idx := strings.IndexAny(value, "#;"); idx >= 0 {
		return strings.TrimSpace(value[:idx])
	}
	return value
}

func normalizeURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	if strings.Contains(raw, "://") {
		return raw
	}
	return "http://" + raw
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func main() {
	ohttpEnabled, err := parseOHTTPFlag(os.Args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(2)
	}

	model := firstNonEmpty(os.Getenv(envModelName), defaultModel)
	prompt := firstNonEmpty(os.Getenv(envPromptText), defaultPrompt)
	fakeSecret := firstNonEmpty(os.Getenv(envFakeSecret), defaultFakeSecret)

	badge, err := makeBadge(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create badge: %v\n", err)
		os.Exit(1)
	}

	var routerURL string
	var routerSource string
	var relayURL string
	var relaySource string
	var seedsJSON string
	var seedsSource string

	if ohttpEnabled {
		relayURL, relaySource, err = resolveRelayURL()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to resolve relay URL: %v\n", err)
			os.Exit(1)
		}
		seedsJSON, seedsSource, err = resolveOHTTPSeedsJSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to resolve OHTTP seeds JSON: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "OHTTP enabled: using relay URL (%s): %s\n", relaySource, relayURL)
		fmt.Fprintf(os.Stderr, "OHTTP enabled: using seeds JSON (%s)\n", seedsSource)
	} else {
		routerURL, routerSource, err = resolveRouterURL()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to resolve router URL: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "OHTTP disabled: using router URL (%s): %s\n", routerSource, routerURL)
	}

	cfg := openpcc.DefaultConfig()
	if ohttpEnabled {
		cfg.APIURL = "http://localhost:0000"
	} else {
		cfg.APIURL = routerURL
	}
	cfg.APIKey = "local-test"
	cfg.PingRouter = false
	policy := inttest.LocalDevIdentityPolicy()
	cfg.TransparencyIdentityPolicy = &policy
	cfg.TransparencyIdentityPolicySource = openpcc.IdentityPolicySourceConfigured

	nonAnonClient := newProxyHTTPClient()
	options := []openpcc.Option{
		openpcc.WithWallet(&fixedWallet{}),
		openpcc.WithNonAnonHTTPClient(nonAnonClient),
		openpcc.WithFakeAttestationSecret(fakeSecret),
	}

	remoteConfig := authclient.RemoteConfig{}
	if ohttpEnabled {
		seeds, err := parseOHTTPSeedsJSON(seedsJSON)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to parse OHTTP seeds JSON: %v\n", err)
			os.Exit(1)
		}
		keyConfigs, rotationPeriods, err := buildOHTTPKeyMaterial(seeds)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to build OHTTP key configs: %v\n", err)
			os.Exit(1)
		}
		remoteConfig = authclient.RemoteConfig{
			OHTTPRelayURLs:          []string{relayURL},
			OHTTPKeyConfigs:         keyConfigs,
			OHTTPKeyRotationPeriods: rotationPeriods,
		}
	} else {
		anonClient := newProxyHTTPClient()
		options = append(options, openpcc.WithRouterURL(routerURL), openpcc.WithAnonHTTPClient(anonClient))
	}

	options = append(options, openpcc.WithAuthClient(fakeAuthClient{
		badge:        badge,
		remoteConfig: remoteConfig,
	}))

	client, err := openpcc.NewFromConfig(
		context.Background(),
		cfg,
		options...,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize OpenPCC client: %v\n", err)
		os.Exit(1)
	}
	defer client.Close(context.Background())

	payload, err := json.Marshal(map[string]interface{}{
		"model":  model,
		"prompt": prompt,
		"stream": false,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to build request body: %v\n", err)
		os.Exit(1)
	}

	req, err := http.NewRequest("POST", "http://confsec.invalid/api/generate", bytes.NewReader(payload))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create request: %v\n", err)
		os.Exit(1)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Confsec-Node-Tags", "model="+model)

	resp, err := client.RoundTrip(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Request failed: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read response: %v\n", err)
		os.Exit(1)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fmt.Fprintf(os.Stderr, "Non-OK response: %s\n%s\n", resp.Status, string(body))
		os.Exit(1)
	}

	fmt.Println(string(body))
}
