package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
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
	"github.com/openpcc/openpcc/attestation/verify"
	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/anonpay/currency"
	"github.com/openpcc/openpcc/anonpay/wallet"
	authclient "github.com/openpcc/openpcc/auth/client"
	"github.com/openpcc/openpcc/auth/credentialing"
	"github.com/openpcc/openpcc/gateway"
	"github.com/openpcc/openpcc/inttest"
	"github.com/openpcc/openpcc/keyrotation"
	"github.com/openpcc/openpcc/transparency"
)

const (
	configPath       = "/etc/nnstreamer/hybrid.ini"
	defaultRouterURL = "http://localhost:3600"
	defaultModel     = "llama3.2:1b"
	defaultPrompt    = "Hello from OpenPCC."

	envRouterURL         = "ROUTER_URL"
	envAltRouterURL      = "OPENPCC_ROUTER_URL"
	envRelayURL          = "RELAY_URL"
	envAltRelayURL       = "OPENPCC_RELAY_URL"
	envServer3URL        = "SERVER3_URL"
	envAltServer3URL     = "OPENPCC_SERVER3_URL"
	envModelName         = "MODEL_NAME"
	envPromptText        = "PROMPT_TEXT"

	envOIDCIssuer       = "OPENPCC_OIDC_ISSUER"
	envOIDCIssuerRegex  = "OPENPCC_OIDC_ISSUER_REGEX"
	envOIDCSubject      = "OPENPCC_OIDC_SUBJECT"
	envOIDCSubjectRegex = "OPENPCC_OIDC_SUBJECT_REGEX"

	envTransparencyEnv   = "TRANSPARENCY_ENV"
	envSigstoreCachePath = "SIGSTORE_CACHE_PATH"
	routerURLConfigKey   = "router_url"
	relayURLConfigKey    = "relay_url"
	server3URLConfigKey  = "server3_url"
	authURLConfigKey     = "auth_url"
	oidcIssuerConfigKey  = "oidc_issuer"
	oidcIssuerRegexKey   = "oidc_issuer_regex"
	oidcSubjectConfigKey = "oidc_subject"
	oidcSubjectRegexKey  = "oidc_subject_regex"
	transparencyEnvKey   = "transparency_env"
	sigstoreCachePathKey = "sigstore_cache_path"
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

const (
	server3KeyBundleFormat = "openpcc.ohttp.keybundle.v0.002"
	publicKeyFormatSHA256  = "sha256-seed"
)

type server3OHTTPKeyBundle struct {
	Format string                 `json:"format"`
	Keys   []server3OHTTPKeyEntry `json:"keys"`
}

type server3OHTTPKeyEntry struct {
	KeyID           string `json:"key_id"`
	PublicKeyB64    string `json:"public_key_b64"`
	PublicKeyFormat string `json:"public_key_format"`
}

type server3OHTTPRotationPeriod struct {
	KeyID       string `json:"key_id"`
	ActiveFrom  string `json:"active_from"`
	ActiveUntil string `json:"active_until"`
}

type server3Config struct {
	Features struct {
		OHTTP           bool `json:"ohttp"`
		RealAttestation bool `json:"real_attestation"`
	} `json:"features"`
	RelayURLs  []string `json:"relay_urls"`
	RouterURL  string   `json:"router_url"`
	GatewayURL string   `json:"gateway_url"`
	OHTTPKeyConfigsBundle    string                       `json:"ohttp_key_configs_bundle"`
	OHTTPKeyRotationPeriods  []server3OHTTPRotationPeriod `json:"ohttp_key_rotation_periods"`
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

func parseOHTTPKeyBundle(bundleB64 string) (ohttp.KeyConfigs, error) {
	raw := strings.TrimSpace(bundleB64)
	if raw == "" {
		return nil, fmt.Errorf("server-3 ohttp_key_configs_bundle is empty")
	}
	bundleBytes, err := decodeBase64(raw, "ohttp_key_configs_bundle")
	if err != nil {
		return nil, err
	}

	var bundle server3OHTTPKeyBundle
	if err := json.Unmarshal(bundleBytes, &bundle); err != nil {
		return nil, fmt.Errorf("invalid ohttp_key_configs_bundle JSON: %w", err)
	}
	if bundle.Format != server3KeyBundleFormat {
		return nil, fmt.Errorf("unsupported ohttp key bundle format %q", bundle.Format)
	}
	if len(bundle.Keys) == 0 {
		return nil, fmt.Errorf("ohttp key bundle has no keys")
	}

	kemID, kdfID, aeadID := gateway.Suite.Params()
	keyConfigs := make(ohttp.KeyConfigs, 0, len(bundle.Keys))
	seen := map[byte]struct{}{}

	for idx, entry := range bundle.Keys {
		if strings.TrimSpace(entry.KeyID) == "" {
			return nil, fmt.Errorf("ohttp key bundle keys[%d].key_id is required", idx)
		}
		if strings.TrimSpace(entry.PublicKeyB64) == "" {
			return nil, fmt.Errorf("ohttp key bundle keys[%d].public_key_b64 is required", idx)
		}
		if strings.TrimSpace(entry.PublicKeyFormat) == "" {
			return nil, fmt.Errorf("ohttp key bundle keys[%d].public_key_format is required", idx)
		}
		if entry.PublicKeyFormat != publicKeyFormatSHA256 {
			return nil, fmt.Errorf("unsupported public_key_format %q", entry.PublicKeyFormat)
		}

		keyID, err := parseKeyID(entry.KeyID)
		if err != nil {
			return nil, fmt.Errorf("ohttp key bundle keys[%d].key_id invalid: %w", idx, err)
		}
		if _, ok := seen[keyID]; ok {
			return nil, fmt.Errorf("ohttp key bundle keys[%d].key_id is duplicated: %s", idx, entry.KeyID)
		}
		seen[keyID] = struct{}{}

		seedBytes, err := decodeBase64(strings.TrimSpace(entry.PublicKeyB64), "ohttp_key_configs_bundle.keys[].public_key_b64")
		if err != nil {
			return nil, err
		}
		if len(seedBytes) != kemID.Scheme().SeedSize() {
			return nil, fmt.Errorf(
				"ohttp key bundle keys[%d].public_key_b64 seed length must be %d bytes, got %d",
				idx,
				kemID.Scheme().SeedSize(),
				len(seedBytes),
			)
		}
		publicKey, _ := kemID.Scheme().DeriveKeyPair(seedBytes)
		keyConfigs = append(keyConfigs, ohttp.KeyConfig{
			KeyID:     keyID,
			KemID:     kemID,
			PublicKey: publicKey,
			SymmetricAlgorithms: []ohttp.SymmetricAlgorithm{
				{
					KDFID:  kdfID,
					AEADID: aeadID,
				},
			},
		})
	}

	return keyConfigs, nil
}

func parseOHTTPRotationPeriods(periods []server3OHTTPRotationPeriod) ([]gateway.KeyRotationPeriodWithID, error) {
	if len(periods) == 0 {
		return nil, fmt.Errorf("ohttp_key_rotation_periods is empty")
	}
	rotation := make([]gateway.KeyRotationPeriodWithID, 0, len(periods))
	seen := map[byte]struct{}{}

	for idx, period := range periods {
		if strings.TrimSpace(period.KeyID) == "" {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].key_id is required", idx)
		}
		if strings.TrimSpace(period.ActiveFrom) == "" {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].active_from is required", idx)
		}
		if strings.TrimSpace(period.ActiveUntil) == "" {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].active_until is required", idx)
		}

		keyID, err := parseKeyID(period.KeyID)
		if err != nil {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].key_id invalid: %w", idx, err)
		}
		if _, ok := seen[keyID]; ok {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].key_id is duplicated: %s", idx, period.KeyID)
		}
		seen[keyID] = struct{}{}

		activeFrom, err := time.Parse(time.RFC3339, period.ActiveFrom)
		if err != nil {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].active_from invalid: %w", idx, err)
		}
		activeUntil, err := time.Parse(time.RFC3339, period.ActiveUntil)
		if err != nil {
			return nil, fmt.Errorf("ohttp_key_rotation_periods[%d].active_until invalid: %w", idx, err)
		}

		rotation = append(rotation, gateway.KeyRotationPeriodWithID{
			Period: keyrotation.Period{
				ActiveFrom:  activeFrom,
				ActiveUntil: activeUntil,
			},
			KeyID: keyID,
		})
	}

	return rotation, nil
}

func validateOHTTPRotationKeys(keyConfigs ohttp.KeyConfigs, rotation []gateway.KeyRotationPeriodWithID) error {
	if len(keyConfigs) == 0 {
		return fmt.Errorf("ohttp key bundle has no keys")
	}
	keyIDs := map[byte]struct{}{}
	for _, key := range keyConfigs {
		keyIDs[key.KeyID] = struct{}{}
	}
	for _, period := range rotation {
		if _, ok := keyIDs[period.KeyID]; !ok {
			return fmt.Errorf("ohttp rotation key_id %d missing from key bundle", period.KeyID)
		}
	}
	return nil
}

func decodeBase64(value, field string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err == nil {
		return decoded, nil
	}
	decoded, rawErr := base64.RawStdEncoding.DecodeString(value)
	if rawErr == nil {
		return decoded, nil
	}
	return nil, fmt.Errorf("%s must be base64: %w", field, err)
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

func loadINI(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, err
	}
	defer file.Close()

	values := map[string]string{}
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
		value = stripInlineComment(value)
		value = strings.TrimSpace(strings.Trim(value, `"'`))
		if value == "" {
			continue
		}
		values[strings.ToLower(key)] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return values, nil
}

func resolveRouterURL(config map[string]string) (string, string) {
	if value := strings.TrimSpace(os.Getenv(envAltRouterURL)); value != "" {
		return normalizeURL(value), "env"
	}
	if value := strings.TrimSpace(os.Getenv(envRouterURL)); value != "" {
		return normalizeURL(value), "env"
	}

	for _, key := range []string{routerURLConfigKey, "server1_url", "server_1_url"} {
		if value := strings.TrimSpace(config[key]); value != "" {
			return normalizeURL(value), "config"
		}
	}

	return defaultRouterURL, "default"
}

func resolveRelayURL(config map[string]string) (string, string, error) {
	if value := strings.TrimSpace(os.Getenv(envAltRelayURL)); value != "" {
		return normalizeURL(value), "env", nil
	}
	if value := strings.TrimSpace(os.Getenv(envRelayURL)); value != "" {
		return normalizeURL(value), "env", nil
	}
	if value := strings.TrimSpace(config[relayURLConfigKey]); value != "" {
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

func resolveServer3URL(config map[string]string) (string, string) {
	if value := strings.TrimSpace(os.Getenv(envAltServer3URL)); value != "" {
		return normalizeURL(value), "env"
	}
	if value := strings.TrimSpace(os.Getenv(envServer3URL)); value != "" {
		return normalizeURL(value), "env"
	}
	for _, key := range []string{server3URLConfigKey, authURLConfigKey} {
		if value := strings.TrimSpace(config[key]); value != "" {
			return normalizeURL(value), "config"
		}
	}
	return "", ""
}

func fetchServer3Config(ctx context.Context, client *http.Client, server3URL string) (server3Config, error) {
	if client == nil {
		client = http.DefaultClient
	}
	baseURL := strings.TrimRight(server3URL, "/")
	configURL := baseURL + "/api/config"
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, configURL, nil)
	if err != nil {
		return server3Config{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return server3Config{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return server3Config{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return server3Config{}, fmt.Errorf("server-3 config error: %s: %s", resp.Status, string(body))
	}

	var payload server3Config
	if err := json.Unmarshal(body, &payload); err != nil {
		return server3Config{}, err
	}
	return payload, nil
}

func resolveIdentityPolicy(config map[string]string) (transparency.IdentityPolicy, string, error) {
	policy := transparency.IdentityPolicy{
		OIDCIssuer:       strings.TrimSpace(config[oidcIssuerConfigKey]),
		OIDCIssuerRegex:  strings.TrimSpace(config[oidcIssuerRegexKey]),
		OIDCSubject:      strings.TrimSpace(config[oidcSubjectConfigKey]),
		OIDCSubjectRegex: strings.TrimSpace(config[oidcSubjectRegexKey]),
	}
	source := "config"

	envPolicy := transparency.IdentityPolicy{
		OIDCIssuer:       firstEnv(envOIDCIssuer, "OIDC_ISSUER"),
		OIDCIssuerRegex:  firstEnv(envOIDCIssuerRegex, "OIDC_ISSUER_REGEX"),
		OIDCSubject:      firstEnv(envOIDCSubject, "OIDC_SUBJECT"),
		OIDCSubjectRegex: firstEnv(envOIDCSubjectRegex, "OIDC_SUBJECT_REGEX"),
	}
	if hasIdentityPolicy(envPolicy) {
		policy = mergePolicy(policy, envPolicy)
		source = "env"
	}

	if !hasIdentityPolicy(policy) {
		return transparency.IdentityPolicy{}, "", fmt.Errorf(
			"missing OIDC identity policy (set env vars or %s keys)",
			configPath,
		)
	}
	if !isIdentityPolicyValid(policy) {
		return transparency.IdentityPolicy{}, "", fmt.Errorf(
			"identity policy must set issuer/issuer_regex and subject/subject_regex",
		)
	}

	return policy, source, nil
}

func resolveTransparencyEnv(config map[string]string) (transparency.Environment, string, error) {
	if value := strings.TrimSpace(os.Getenv(envTransparencyEnv)); value != "" {
		env := transparency.Environment(strings.ToLower(value))
		if err := env.Validate(); err != nil {
			return "", "", err
		}
		return env, "env", nil
	}
	if value := strings.TrimSpace(config[transparencyEnvKey]); value != "" {
		env := transparency.Environment(strings.ToLower(value))
		if err := env.Validate(); err != nil {
			return "", "", err
		}
		return env, "config", nil
	}
	return "", "", nil
}

func resolveSigstoreCachePath(config map[string]string) (string, string) {
	if value := strings.TrimSpace(os.Getenv(envSigstoreCachePath)); value != "" {
		return value, "env"
	}
	if value := strings.TrimSpace(config[sigstoreCachePathKey]); value != "" {
		return value, "config"
	}
	return "", ""
}

func hasIdentityPolicy(policy transparency.IdentityPolicy) bool {
	return policy.OIDCIssuer != "" ||
		policy.OIDCIssuerRegex != "" ||
		policy.OIDCSubject != "" ||
		policy.OIDCSubjectRegex != ""
}

func isIdentityPolicyValid(policy transparency.IdentityPolicy) bool {
	hasIssuer := policy.OIDCIssuer != "" || policy.OIDCIssuerRegex != ""
	hasSubject := policy.OIDCSubject != "" || policy.OIDCSubjectRegex != ""
	return hasIssuer && hasSubject
}

func mergePolicy(base, override transparency.IdentityPolicy) transparency.IdentityPolicy {
	if override.OIDCIssuer != "" {
		base.OIDCIssuer = override.OIDCIssuer
	}
	if override.OIDCIssuerRegex != "" {
		base.OIDCIssuerRegex = override.OIDCIssuerRegex
	}
	if override.OIDCSubject != "" {
		base.OIDCSubject = override.OIDCSubject
	}
	if override.OIDCSubjectRegex != "" {
		base.OIDCSubjectRegex = override.OIDCSubjectRegex
	}
	return base
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

func firstEnv(keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
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

	config, err := loadINI(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read %s: %v\n", configPath, err)
		os.Exit(1)
	}

	model := firstNonEmpty(os.Getenv(envModelName), defaultModel)
	prompt := firstNonEmpty(os.Getenv(envPromptText), defaultPrompt)
	nonAnonClient := newProxyHTTPClient()

	var routerURL string
	var routerSource string
	var relayURL string
	var relaySource string
	var server3URL string
	var server3Source string
	var server3Payload *server3Config

	if ohttpEnabled {
		server3URL, server3Source = resolveServer3URL(config)
		if server3URL == "" {
			fmt.Fprintln(os.Stderr, "OHTTP enabled: server-3 URL is required (set SERVER3_URL or OPENPCC_SERVER3_URL)")
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "Fetching server-3 config (%s): %s/api/config\n", server3Source, strings.TrimRight(server3URL, "/"))
		payload, fetchErr := fetchServer3Config(context.Background(), nonAnonClient, server3URL)
		if fetchErr != nil {
			fmt.Fprintf(os.Stderr, "Failed to fetch server-3 config: %v\n", fetchErr)
			os.Exit(1)
		}
		server3Payload = &payload
		fmt.Fprintf(os.Stderr, "server-3 features: ohttp=%t real_attestation=%t\n", payload.Features.OHTTP, payload.Features.RealAttestation)
		if !payload.Features.OHTTP {
			fmt.Fprintln(os.Stderr, "server-3 config reports ohttp disabled; cannot proceed with -ohttp=enable")
			os.Exit(1)
		}
		if len(payload.RelayURLs) > 0 {
			fmt.Fprintf(os.Stderr, "server-3 relay_urls: %s\n", strings.Join(payload.RelayURLs, ", "))
		} else {
			fmt.Fprintln(os.Stderr, "server-3 relay_urls: <empty>")
		}
		if strings.TrimSpace(payload.RouterURL) != "" {
			routerURL = normalizeURL(payload.RouterURL)
			routerSource = "server-3"
			fmt.Fprintf(os.Stderr, "server-3 router_url: %s\n", routerURL)
		}

		relayURL, relaySource, err = resolveRelayURL(config)
		if err != nil {
			if server3Payload != nil && len(server3Payload.RelayURLs) > 0 {
				relayURL = server3Payload.RelayURLs[0]
				relaySource = "server-3"
			} else {
				fmt.Fprintf(os.Stderr, "Failed to resolve relay URL: %v\n", err)
				os.Exit(1)
			}
		}
		if routerURL == "" {
			routerURL, routerSource = resolveRouterURL(config)
			if routerURL == "" {
				fmt.Fprintln(os.Stderr, "Failed to resolve router URL for oHTTP mode")
				os.Exit(1)
			}
		}
		fmt.Fprintf(os.Stderr, "OHTTP enabled: using relay URL (%s): %s\n", relaySource, relayURL)
		fmt.Fprintf(os.Stderr, "OHTTP enabled: using router URL (%s): %s\n", routerSource, routerURL)
	} else {
		routerURL, routerSource = resolveRouterURL(config)
		fmt.Fprintf(os.Stderr, "OHTTP disabled: using router URL (%s): %s\n", routerSource, routerURL)
	}

	policy, policySource, err := resolveIdentityPolicy(config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Identity policy error: %v\n", err)
		os.Exit(1)
	}

	cfg := openpcc.DefaultConfig()
	cfg.APIURL = "http://localhost:0000"
	cfg.APIKey = "local-test"
	cfg.PingRouter = false
	cfg.TransparencyIdentityPolicySource = openpcc.IdentityPolicySourceConfigured
	cfg.TransparencyIdentityPolicy = &policy

	if env, source, err := resolveTransparencyEnv(config); err != nil {
		fmt.Fprintf(os.Stderr, "Transparency env error: %v\n", err)
		os.Exit(1)
	} else if env != "" {
		cfg.TransparencyVerifier.Environment = env
		fmt.Fprintf(os.Stderr, "Using transparency env (%s): %s\n", source, env)
	}

	if cachePath, source := resolveSigstoreCachePath(config); cachePath != "" {
		cfg.TransparencyVerifier.LocalTrustedRootCachePath = cachePath
		fmt.Fprintf(os.Stderr, "Using sigstore cache path (%s): %s\n", source, cachePath)
	}

	fmt.Fprintf(os.Stderr, "Using identity policy (%s)\n", policySource)

	badge, err := makeBadge(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create badge: %v\n", err)
		os.Exit(1)
	}

	options := []openpcc.Option{
		openpcc.WithWallet(&fixedWallet{}),
		openpcc.WithNonAnonHTTPClient(nonAnonClient),
	}

	remoteConfig := authclient.RemoteConfig{}
	var anonClient *http.Client
	if ohttpEnabled {
		if server3Payload == nil {
			fmt.Fprintln(os.Stderr, "OHTTP enabled: server-3 config is required but missing")
			os.Exit(1)
		}
		keyConfigs, err := parseOHTTPKeyBundle(server3Payload.OHTTPKeyConfigsBundle)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to parse server-3 ohttp key bundle: %v\n", err)
			os.Exit(1)
		}
		rotationPeriods, err := parseOHTTPRotationPeriods(server3Payload.OHTTPKeyRotationPeriods)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to parse server-3 ohttp rotation periods: %v\n", err)
			os.Exit(1)
		}
		if err := validateOHTTPRotationKeys(keyConfigs, rotationPeriods); err != nil {
			fmt.Fprintf(os.Stderr, "Invalid server-3 ohttp config: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "server-3 ohttp key bundle: %d keys, %d rotation entries\n", len(keyConfigs), len(rotationPeriods))

		anonClient, err = buildOHTTPClient(nonAnonClient, relayURL, keyConfigs, rotationPeriods)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to build OHTTP client: %v\n", err)
			os.Exit(1)
		}
		remoteConfig = authclient.RemoteConfig{
			OHTTPRelayURLs:          []string{relayURL},
			OHTTPKeyConfigs:         keyConfigs,
			OHTTPKeyRotationPeriods: rotationPeriods,
			RouterURL:               routerURL,
		}
		options = append(options, openpcc.WithRouterURL(routerURL), openpcc.WithAnonHTTPClient(anonClient))
	} else {
		anonClient = newProxyHTTPClient()
		options = append(options, openpcc.WithRouterURL(routerURL), openpcc.WithAnonHTTPClient(anonClient))
	}

	fakeAuth := fakeAuthClient{
		badge:        badge,
		remoteConfig: remoteConfig,
	}

	verifier, err := transparency.NewVerifier(cfg.TransparencyVerifier, nonAnonClient)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create transparency verifier: %v\n", err)
		os.Exit(1)
	}
	nodeVerifier := verify.NewConfidentSecurityVerifier(
		transparency.NewCachedVerifier(verifier),
		*cfg.TransparencyIdentityPolicy,
	)
	nodeFinder := newLenientNodeFinder(anonClient, fakeAuth, nodeVerifier, routerURL)

	options = append(options,
		openpcc.WithAuthClient(fakeAuth),
		openpcc.WithVerifiedNodeFinder(nodeFinder),
	)

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
