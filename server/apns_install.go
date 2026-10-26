package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
)

// Official release packages supply this private file at installation. Never replace
// an identity already configured by the operator, including the existing test server.
func (a *App) importInstalledAPNsIdentity(ctx context.Context) error {
	if a.cfg.APNsIdentityFile == "" {
		return nil
	}
	raw, err := os.ReadFile(a.cfg.APNsIdentityFile)
	if err != nil || len(raw) > 16384 {
		return errors.New("installed APNs identity unavailable")
	}
	var identity APNsConfig
	if json.Unmarshal(raw, &identity) != nil || !appleID.MatchString(identity.KeyID) || !appleID.MatchString(identity.TeamID) || !bundleID.MatchString(identity.Topic) {
		return errors.New("invalid installed APNs identity")
	}
	if _, err = parseKey(identity.PrivateKey); err != nil {
		return err
	}
	sealed, err := a.seal(canonical(identity))
	if err != nil {
		return err
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, "INSERT INTO settings(key,value) VALUES('apns',$1) ON CONFLICT(key) DO NOTHING", sealed)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		if _, err = tx.Exec(ctx, "UPDATE outbox SET status='queued',available_at=now(),error=NULL WHERE status='blocked' AND error='apns_not_configured' AND expires_at>now()"); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
