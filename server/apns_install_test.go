package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func TestInstalledAPNsIdentityIsEncryptedAndPreservesOverride(t *testing.T) {
	f := setup(t)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	identity := APNsConfig{KeyID: "ABCDEFGHIJ", TeamID: "KLMNOPQRST", Topic: "app.vaovao.push", PrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw}))}
	path := filepath.Join(t.TempDir(), "identity.json")
	encoded, _ := json.Marshal(identity)
	if err = os.WriteFile(path, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	f.a.cfg.APNsIdentityFile = path
	if err = f.a.importInstalledAPNsIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	first, err := f.a.appleConfig(context.Background())
	if err != nil || first.KeyID != identity.KeyID {
		t.Fatal("identity was not installed")
	}
	var sealed []byte
	if err = f.a.db.QueryRow(context.Background(), "SELECT value FROM settings WHERE key='apns'").Scan(&sealed); err != nil {
		t.Fatal(err)
	}
	if string(sealed) == string(encoded) {
		t.Fatal("identity stored in plaintext")
	}
	identity.KeyID = "ZZZZZZZZZZ"
	encoded, _ = json.Marshal(identity)
	_ = os.WriteFile(path, encoded, 0600)
	if err = f.a.importInstalledAPNsIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	existing, err := f.a.appleConfig(context.Background())
	if err != nil || existing.KeyID != first.KeyID {
		t.Fatal("operator identity was overwritten on restart")
	}
	_ = os.WriteFile(path, []byte("{}"), 0600)
	if f.a.importInstalledAPNsIdentity(context.Background()) == nil {
		t.Fatal("invalid installation identity was accepted")
	}
}
