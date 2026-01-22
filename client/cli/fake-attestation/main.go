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
)

const (
	configPath         = "/etc/nnstreamer/hybrid.ini"
	defaultRouterURL   = "http://localhost:3600"
	defaultModel       = "llama3.2:1b"
	defaultPrompt      = "Hello from OpenPCC."
	defaultFakeSecret  = "123456"
	envRouterURL       = "ROUTER_URL"
	envAltRouterURL    = "OPENPCC_ROUTER_URL"
	envModelName       = "MODEL_NAME"
	envPromptText      = "PROMPT_TEXT"
	envFakeSecret      = "FAKE_ATTESTATION_SECRET"
	routerURLConfigKey = "router_url"
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

func routerURLFromConfig(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	defer file.Close()

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
		if key != routerURLConfigKey && key != "server1_url" && key != "server_1_url" {
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
	routerURL, source, err := resolveRouterURL()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to resolve router URL: %v\n", err)
		os.Exit(1)
	}

	model := firstNonEmpty(os.Getenv(envModelName), defaultModel)
	prompt := firstNonEmpty(os.Getenv(envPromptText), defaultPrompt)
	fakeSecret := firstNonEmpty(os.Getenv(envFakeSecret), defaultFakeSecret)

	fmt.Fprintf(os.Stderr, "Using router URL (%s): %s\n", source, routerURL)

	badge, err := makeBadge(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create badge: %v\n", err)
		os.Exit(1)
	}

	cfg := openpcc.DefaultConfig()
	cfg.APIURL = routerURL
	cfg.APIKey = "local-test"
	cfg.PingRouter = false
	policy := inttest.LocalDevIdentityPolicy()
	cfg.TransparencyIdentityPolicy = &policy
	cfg.TransparencyIdentityPolicySource = openpcc.IdentityPolicySourceConfigured

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
		openpcc.WithFakeAttestationSecret(fakeSecret),
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
