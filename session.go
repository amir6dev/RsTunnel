package httpmux

import (
	"sync"
	"time"
)

type Session struct {
	ID      string
	Created time.Time
	Updated time.Time

	Outgoing chan *Frame
}

type SessionManager struct {
	timeout time.Duration

	mu       sync.Mutex
	sessions map[string]*Session
}

func NewSessionManager(timeout time.Duration) *SessionManager {
	return &SessionManager{
		timeout:  timeout,
		sessions: make(map[string]*Session),
	}
}

func (sm *SessionManager) GetOrCreate(id string) *Session {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	if s, ok := sm.sessions[id]; ok {
		s.Updated = time.Now()
		return s
	}
	s := &Session{
		ID:       id,
		Created:  time.Now(),
		Updated:  time.Now(),
		Outgoing: make(chan *Frame, 8192),
	}
	sm.sessions[id] = s
	return s
}
