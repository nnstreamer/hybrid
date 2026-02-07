package main

import (
	"net/http"
	"testing"
	"time"

	"github.com/openpcc/openpcc/gateway"
	"github.com/openpcc/openpcc/keyrotation"
)

func TestBuildOHTTPClientNoActiveKeys(t *testing.T) {
	keyConfigs, err := gateway.GenerateKeyConfigs([][]byte{make([]byte, 32)})
	if err != nil {
		t.Fatalf("failed to generate key configs: %v", err)
	}
	period := keyrotation.Period{
		ActiveFrom:  time.Now().Add(1 * time.Hour),
		ActiveUntil: time.Now().Add(2 * time.Hour),
	}
	rotation := []gateway.KeyRotationPeriodWithID{
		{Period: period, KeyID: 0},
	}

	if _, err := buildOHTTPClient(http.DefaultClient, "http://relay", keyConfigs, rotation); err == nil {
		t.Fatalf("expected error for no active keys")
	}
}

func TestBuildOHTTPClientMissingKeyConfig(t *testing.T) {
	keyConfigs, err := gateway.GenerateKeyConfigs([][]byte{make([]byte, 32)})
	if err != nil {
		t.Fatalf("failed to generate key configs: %v", err)
	}
	period := keyrotation.Period{
		ActiveFrom:  time.Now().Add(-1 * time.Minute),
		ActiveUntil: time.Now().Add(1 * time.Hour),
	}
	rotation := []gateway.KeyRotationPeriodWithID{
		{Period: period, KeyID: 1},
	}

	if _, err := buildOHTTPClient(http.DefaultClient, "http://relay", keyConfigs, rotation); err == nil {
		t.Fatalf("expected error for missing key config")
	}
}

func TestBuildOHTTPClientSuccess(t *testing.T) {
	keyConfigs, err := gateway.GenerateKeyConfigs([][]byte{make([]byte, 32)})
	if err != nil {
		t.Fatalf("failed to generate key configs: %v", err)
	}
	period := keyrotation.Period{
		ActiveFrom:  time.Now().Add(-1 * time.Minute),
		ActiveUntil: time.Now().Add(1 * time.Hour),
	}
	rotation := []gateway.KeyRotationPeriodWithID{
		{Period: period, KeyID: 0},
	}

	client, err := buildOHTTPClient(http.DefaultClient, "http://relay", keyConfigs, rotation)
	if err != nil {
		t.Fatalf("expected success, got error: %v", err)
	}
	if client == nil {
		t.Fatalf("expected client, got nil")
	}
	if client.Transport == nil {
		t.Fatalf("expected transport to be set")
	}
}
