package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/openpcc/openpcc"
	"github.com/openpcc/openpcc/ahttp"
	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/anonpay/currency"
	"github.com/openpcc/openpcc/anonpay/wallet"
	authclient "github.com/openpcc/openpcc/auth/client"
	"github.com/openpcc/openpcc/auth/credentialing"
	"github.com/openpcc/openpcc/inttest"
	"github.com/openpcc/openpcc/transparency"
)

const (
	configPath       = "/etc/nnstreamer/hybrid.ini"
	defaultRouterURL = "http://localhost:3600"
	defaultModel     = "llama3.2:1b"
	defaultPrompt    = "Hello from OpenPCC."

	envRouterURL    = "ROUTER_URL"
	envAltRouterURL = "OPENPCC_ROUTER_URL"
	envModelName    = "MODEL_NAME"
	envPromptText   = "PROMPT_TEXT"

	envOIDCIssuer       = "OPENPCC_OIDC_ISSUER"
	envOIDCIssuerRegex  = "OPENPCC_OIDC_ISSUER_REGEX"
	envOIDCSubject      = "OPENPCC_OIDC_SUBJECT"
	envOIDCSubjectRegex = "OPENPCC_OIDC_SUBJECT_REGEX"

	envTransparencyEnv   = "TRANSPARENCY_ENV"
	envSigstoreCachePath = "SIGSTORE_CACHE_PATH"
	routerURLConfigKey   = "router_url"
	oidcIssuerConfigKey  = "oidc_issuer"
	oidcIssuerRegexKey   = "oidc_issuer_regex"
	oidcSubjectConfigKey = "oidc_subject"
	oidcSubjectRegexKey  = "oidc_subject_regex"
	transparencyEnvKey   = "transparency_env"
	sigstoreCachePathKey = "sigstore_cache_path"
)

type fakeAuthClient struct {
	badge credentialing.Badge
}

func (f fakeAuthClient) RemoteConfig() authclient.RemoteConfig {
	return authclient.RemoteConfig{}
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
	config, err := loadINI(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read %s: %v\n", configPath, err)
		os.Exit(1)
	}

	routerURL, routerSource := resolveRouterURL(config)
	model := firstNonEmpty(os.Getenv(envModelName), defaultModel)
	prompt := firstNonEmpty(os.Getenv(envPromptText), defaultPrompt)

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

	fmt.Fprintf(os.Stderr, "Using router URL (%s): %s\n", routerSource, routerURL)
	fmt.Fprintf(os.Stderr, "Using identity policy (%s)\n", policySource)

	badge, err := makeBadge(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create badge: %v\n", err)
		os.Exit(1)
	}

	nonAnonClient := newProxyHTTPClient()
	anonClient := newProxyHTTPClient()

	client, err := openpcc.NewFromConfig(
		context.Background(),
		cfg,
		openpcc.WithAuthClient(fakeAuthClient{badge: badge}),
		openpcc.WithWallet(&fixedWallet{}),
		openpcc.WithRouterURL(routerURL),
		openpcc.WithNonAnonHTTPClient(nonAnonClient),
		openpcc.WithAnonHTTPClient(anonClient),
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
