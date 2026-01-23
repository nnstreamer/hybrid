package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/openpcc/openpcc/ahttp"
	rtrpb "github.com/openpcc/openpcc/gen/protos/router"
	"github.com/openpcc/openpcc/httpfmt"
	routerapi "github.com/openpcc/openpcc/router/api"
	"google.golang.org/protobuf/proto"
)

const (
	configPath       = "/etc/nnstreamer/hybrid.ini"
	defaultRouterURL = "http://localhost:3600"

	envRouterURL    = "ROUTER_URL"
	envAltRouterURL = "OPENPCC_ROUTER_URL"
	envNodeTags     = "NODE_TAGS"
	envMaxNodes     = "MAX_NODES"
	envShowNodes    = "SHOW_NODES"
	envTimeoutSecs  = "REQUEST_TIMEOUT_SECONDS"
	defaultMaxNodes = 100
	defaultTimeout  = 15 * time.Second
	routerURLConfig = "router_url"
)

func main() {
	routerURL, source, err := resolveRouterURL()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to resolve router URL: %v\n", err)
		os.Exit(1)
	}
	routerURL = strings.TrimRight(routerURL, "/")

	maxNodes, err := parseMaxNodes(os.Getenv(envMaxNodes))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Invalid MAX_NODES: %v\n", err)
		os.Exit(1)
	}

	timeout, err := parseTimeout(os.Getenv(envTimeoutSecs))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Invalid REQUEST_TIMEOUT_SECONDS: %v\n", err)
		os.Exit(1)
	}

	tags := parseTagsEnv(os.Getenv(envNodeTags))
	showNodes := parseBool(os.Getenv(envShowNodes))

	fmt.Printf("Router URL (%s): %s\n", source, routerURL)
	if len(tags) > 0 {
		fmt.Printf("Tag filter: %s\n", strings.Join(tags, ", "))
	}
	fmt.Printf("Max nodes: %d\n", maxNodes)
	fmt.Printf("Request timeout: %s\n", timeout)

	client := newProxyHTTPClient()

	healthCtx, cancel := context.WithTimeout(context.Background(), timeout)
	health, err := fetchRouterHealth(healthCtx, client, routerURL)
	cancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Router health check failed: %v\n", err)
	} else {
		fmt.Printf("Router health: %s\n", health)
	}

	manifestCtx, cancel := context.WithTimeout(context.Background(), timeout)
	manifestList, err := fetchComputeManifests(manifestCtx, client, routerURL, tags, maxNodes)
	cancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to fetch compute manifests: %v\n", err)
		os.Exit(1)
	}

	items := manifestList.GetItems()
	fmt.Printf("Compute nodes: %d\n", len(items))
	if len(items) == 0 {
		fmt.Fprintln(os.Stderr, "Warning: router returned 0 compute nodes.")
	}

	if showNodes {
		printNodeDetails(items)
	}
}

func fetchRouterHealth(ctx context.Context, client *http.Client, routerURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, routerURL+"/_health", nil)
	if err != nil {
		return "", err
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	trimmed := strings.TrimSpace(string(body))
	if trimmed == "" {
		return resp.Status, nil
	}
	return fmt.Sprintf("%s %s", resp.Status, trimmed), nil
}

func fetchComputeManifests(
	ctx context.Context,
	client *http.Client,
	routerURL string,
	tags []string,
	limit int,
) (*rtrpb.ComputeManifestList, error) {
	creditHeader, err := attestationCreditHeader(ctx)
	if err != nil {
		return nil, err
	}

	reqPb := &rtrpb.ComputeManifestRequest{}
	reqPb.SetLimit(int32(limit))
	reqPb.SetTags(tags)
	data, err := proto.Marshal(reqPb)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal compute manifest request: %w", err)
	}

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		routerURL+"/compute-manifests",
		bytes.NewReader(data),
	)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set(ahttp.CreditHeader, creditHeader)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode != http.StatusOK {
		msg := decodeBinaryError(body)
		if msg == "" {
			msg = resp.Status
		}
		return nil, fmt.Errorf("router returned %s: %s", resp.Status, msg)
	}

	list := &rtrpb.ComputeManifestList{}
	if err := proto.Unmarshal(body, list); err != nil {
		return nil, fmt.Errorf("failed to decode compute manifest list: %w", err)
	}
	return list, nil
}

func decodeBinaryError(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	msgErr, err := httpfmt.DecodeBinaryErrorAsError(bytes.NewReader(body))
	if err == nil && msgErr != nil {
		return strings.TrimSpace(msgErr.Error())
	}
	return strings.TrimSpace(string(body))
}

func attestationCreditHeader(ctx context.Context) (string, error) {
	credit, err := blindCredit(ctx, ahttp.AttestationCurrencyValue)
	if err != nil {
		return "", fmt.Errorf("failed to create attestation credit: %w", err)
	}
	encoded, err := credit.MarshalText()
	if err != nil {
		return "", fmt.Errorf("failed to encode credit: %w", err)
	}
	return string(encoded), nil
}

func parseMaxNodes(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultMaxNodes, nil
	}
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("MAX_NODES must be a positive integer")
	}
	if value > routerapi.MaxComputeManifests {
		return 0, fmt.Errorf("MAX_NODES must be <= %d", routerapi.MaxComputeManifests)
	}
	return value, nil
}

func parseTimeout(raw string) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultTimeout, nil
	}
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("REQUEST_TIMEOUT_SECONDS must be a positive integer")
	}
	return time.Duration(value) * time.Second, nil
}

func parseTagsEnv(raw string) []string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil
	}
	var parts []string
	if strings.Contains(trimmed, ",") {
		parts = strings.Split(trimmed, ",")
	} else {
		parts = strings.Fields(trimmed)
	}
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		tag := strings.TrimSpace(part)
		if tag != "" {
			out = append(out, tag)
		}
	}
	return out
}

func parseBool(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes", "y", "on":
		return true
	default:
		return false
	}
}

func printNodeDetails(items []*rtrpb.ComputeManifest) {
	if len(items) == 0 {
		return
	}
	fmt.Println("Node details:")
	for idx, item := range items {
		tags := append([]string(nil), item.GetTags()...)
		sort.Strings(tags)
		tagOutput := "<none>"
		if len(tags) > 0 {
			tagOutput = strings.Join(tags, ", ")
		}
		fmt.Printf(" - %d: id=%s tags=%s\n", idx+1, item.GetId(), tagOutput)
	}
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
		if key != routerURLConfig && key != "server1_url" && key != "server_1_url" {
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
