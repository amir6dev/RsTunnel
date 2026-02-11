package httpmux

import (
	"sync"
	"time"
)

type Session struct {
	ID        string
	Created   time.Time
	Updated   time.Time
	Streams   map[uint32]*Stream
	ConnPool  []*HTTPConn
	Mutex     sync.Mutex
}

type SessionManager struct {
	sessions map[string]*Session
	mutex    sync.Mutex
	Timeout  time.Duration
}

func NewSessionManager(timeout time.Duration) *SessionManager {
	return &SessionManager{
		sessions: make(map[string]*Session),
		Timeout:  timeout,
	}
}

func (sm *SessionManager) GetOrCreate(id string) *Session {
	sm.mutex.Lock()
	defer sm.mutex.Unlock()

	sess, ok := sm.sessions[id]
	if ok {
		sess.Updated = time.Now()
		return sess
	}

	sess = &Session{
		ID:       id,
		Created:  time.Now(),
		Updated:  time.Now(),
		Streams:  make(map[uint32]*Stream),
	}
	sm.sessions[id] = sess

	return sess
}

func (sm *SessionManager) Cleanup() {
	sm.mutex.Lock()
	defer sm.mutex.Unlock()

	for id, sess := range sm.sessions {
		if time.Since(sess.Updated) > sm.Timeout {
			delete(sm.sessions, id)
		}
	}
}
