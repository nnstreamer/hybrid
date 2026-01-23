package main

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"time"

	"github.com/openpcc/openpcc"
)

const defaultHTTPClientTimeout = 5 * time.Minute

func newProxyHTTPClient() *http.Client {
	transport := openpcc.DefaultNonAnonTransport.Clone()
	transport.Proxy = http.ProxyFromEnvironment
	transport.TLSClientConfig = withSystemRoots(transport.TLSClientConfig)

	return &http.Client{
		Timeout:   defaultHTTPClientTimeout,
		Transport: transport,
	}
}

func withSystemRoots(cfg *tls.Config) *tls.Config {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		return cfg
	}

	if cfg == nil {
		return &tls.Config{RootCAs: pool}
	}

	clone := cfg.Clone()
	if clone.RootCAs == nil {
		clone.RootCAs = pool
	}
	return clone
}
