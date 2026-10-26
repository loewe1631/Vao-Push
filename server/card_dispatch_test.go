package main

import (
	"context"
	"strings"
	"testing"
)

type cardDispatchProbe struct{ jobs []PushJob }

func (p *cardDispatchProbe) Send(_ context.Context, job PushJob) PushResult {
	p.jobs = append(p.jobs, job)
	return PushResult{Status: "accepted", APNsID: "test-only"}
}

func TestCardWidgetDispatchRechecksSubscription(t *testing.T) {
	for _, tc := range []struct {
		name, kind         string
		revoked, unrelated bool
		want               string
	}{
		{name: "source_update", kind: "source", want: "accepted"},
		{name: "published_design", kind: "design", want: "accepted"},
		{name: "revoked_source", kind: "source", revoked: true, want: "cancelled"},
		{name: "revoked_design", kind: "design", revoked: true, want: "cancelled"},
		{name: "unrelated_resource", kind: "source", unrelated: true, want: "cancelled"},
		{name: "device_stream", kind: "legacy", want: "accepted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := setup(t)
			ctx := context.Background()
			d := f.automatic(t, "Widget consumer")
			device, token := d["binding_id"].(string), d["device_token"].(string)
			widgetToken := strings.Repeat("ab", 32)
			result(t, f.request("PUT", "/v1/device/registration", map[string]any{"environment": "sandbox", "widget_token": widgetToken}, token, nil), 200)
			if tc.kind == "legacy" {
				path := "/v1/state/" + d["send_key"].(string) + "/personal"
				result(t, f.request("PUT", path, goodState(), "", nil), 202)
				result(t, f.request("PUT", "/v1/device/subscriptions", map[string]any{"data_ids": []string{"personal"}}, token, nil), 200)
				next := goodState()
				next["title"] = "Updated personal state"
				result(t, f.request("PUT", path, next, "", nil), 202)
			} else {
				source := f.cardSource(t)
				card := f.publishedCard(t, source)
				cid := card["id"].(string)
				code := result(t, f.request("POST", "/v1/cards/"+cid+"/codes", map[string]any{}, "web", nil), 200)
				result(t, f.request("POST", "/v1/cards/redeem", map[string]any{"code": code["code"]}, token, nil), 200)
				// Web cards never join the device's legacy data-ID subscription list.
				var count int
				if e := f.a.db.QueryRow(ctx, "SELECT jsonb_array_length(subscriptions) FROM devices WHERE id=$1", device).Scan(&count); e != nil || count != 0 {
					t.Fatalf("unexpected legacy subscriptions: %d %v", count, e)
				}
				if tc.kind == "source" {
					result(t, f.request("PUT", strings.TrimPrefix(source["data_url"].(string), f.a.cfg.PublicURL), goodState(), "", nil), 202)
				} else {
					result(t, f.request("POST", "/v1/cards/"+cid+"/publish", map[string]any{}, "web", map[string]string{"If-Match": `"draft-1"`}), 200)
				}
				if tc.revoked {
					result(t, f.request("DELETE", "/v1/card-subscriptions/"+cid, nil, token, nil), 200)
				}
				if tc.unrelated {
					if _, e := f.a.db.Exec(ctx, "UPDATE outbox SET resource_id='unrelated_resource' WHERE device_id=$1", device); e != nil {
						t.Fatal(e)
					}
				}
			}
			probe := &cardDispatchProbe{}
			f.a.push = probe
			if !f.a.workOne(ctx) {
				t.Fatal("queued widget update was not processed")
			}
			var status string
			if e := f.a.db.QueryRow(ctx, "SELECT status FROM outbox WHERE device_id=$1 ORDER BY created_at DESC LIMIT 1", device).Scan(&status); e != nil {
				t.Fatal(e)
			}
			if status != tc.want {
				t.Fatalf("dispatch status %s, want %s", status, tc.want)
			}
			if tc.want == "accepted" {
				if len(probe.jobs) != 1 || probe.jobs[0].Token != widgetToken {
					t.Fatal("authorized widget notification did not reach provider with widget token")
				}
			} else if len(probe.jobs) != 0 {
				t.Fatal("revoked or unrelated update reached provider")
			}
		})
	}
}
