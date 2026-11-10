package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	rpcID              = "analytics"
	maxEventsPerCall   = 500
	maxEventNameLength = 128
	maxSessionIDLength = 64
)

type eventIn struct {
	Name      string                 `json:"name"`
	Ts        int64                  `json:"ts"`
	SessionID string                 `json:"session_id"`
	Props     map[string]interface{} `json:"props"`
}

type payloadIn struct {
	Events []eventIn `json:"events"`
}

func InitModule(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	schema := `CREATE TABLE IF NOT EXISTS analytics_events (
		id BIGSERIAL PRIMARY KEY,
		user_id TEXT NOT NULL DEFAULT '',
		username TEXT NOT NULL DEFAULT '',
		session_id TEXT NOT NULL DEFAULT '',
		event_name TEXT NOT NULL,
		client_ts TIMESTAMPTZ,
		properties JSONB NOT NULL DEFAULT '{}'::jsonb,
		received_at TIMESTAMPTZ NOT NULL DEFAULT now()
	);
	CREATE INDEX IF NOT EXISTS idx_analytics_events_username_ts ON analytics_events (username, client_ts);
	CREATE INDEX IF NOT EXISTS idx_analytics_events_event_ts ON analytics_events (event_name, client_ts);`
	if _, err := db.Exec(schema); err != nil {
		return fmt.Errorf("analytics: schema: %w", err)
	}
	logger.Info("analytics module loaded")
	if err := initializer.RegisterRpc(rpcID, handleAnalytics); err != nil {
		return err
	}
	return nil
}

func handleAnalytics(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	var in payloadIn
	if err := json.Unmarshal([]byte(payload), &in); err != nil {
		return "", errors.New("analytics: malformed payload")
	}
	if len(in.Events) > maxEventsPerCall {
		return "", fmt.Errorf("analytics: too many events (%d > %d)", len(in.Events), maxEventsPerCall)
	}
	for i, ev := range in.Events {
		if ev.Name == "" || len(ev.Name) > maxEventNameLength {
			return "", fmt.Errorf("analytics: event %d has an invalid name", i)
		}
		if len(ev.SessionID) > maxSessionIDLength {
			return "", fmt.Errorf("analytics: event %d has an invalid session_id", i)
		}
	}
	userID, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	username, _ := ctx.Value(runtime.RUNTIME_CTX_USERNAME).(string)

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("analytics: begin tx: %w", err)
	}
	defer tx.Rollback()
	stmt, err := tx.PrepareContext(ctx, `INSERT INTO analytics_events (user_id, username, session_id, event_name, client_ts, properties) VALUES ($1, $2, $3, $4, $5, $6)`)
	if err != nil {
		return "", fmt.Errorf("analytics: prepare: %w", err)
	}
	defer stmt.Close()
	for _, ev := range in.Events {
		var clientTS sql.NullTime
		if ev.Ts > 0 {
			clientTS = sql.NullTime{Time: time.Unix(ev.Ts, 0).UTC(), Valid: true}
		}
		props := []byte("{}")
		if ev.Props != nil {
			if b, err := json.Marshal(ev.Props); err == nil {
				props = b
			}
		}
		if _, err := stmt.ExecContext(ctx, userID, username, ev.SessionID, ev.Name, clientTS, string(props)); err != nil {
			return "", fmt.Errorf("analytics: insert: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("analytics: commit: %w", err)
	}
	logger.Info("analytics: stored %d events for user %s", len(in.Events), username)
	return fmt.Sprintf(`{"ok":true,"count":%d}`, len(in.Events)), nil
}
