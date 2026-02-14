/*
 * RsTunnel Critical Fixes - Part 3: Chunked Encoding & Session Management
 * این فایل fixes مربوط به chunked encoding و session management
 */

package httpmux

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"sync"
	"time"
)

// ============================================================================
// FIX 4: Chunked Encoding واقعی‌تر با jitter و padding
// ============================================================================

// ChunkConfig - تنظیمات chunking
type ChunkConfig struct {
	MinChunkSize int     // حداقل اندازه chunk (bytes)
	MaxChunkSize int     // حداکثر اندازه chunk (bytes)
	JitterFactor float64 // jitter برای اندازه chunk (0.0-1.0)
	AddPadding   bool    // آیا padding اضافه شود؟
}

// DefaultChunkConfig - تنظیمات پیش‌فرض مثل Dagger
func DefaultChunkConfig() *ChunkConfig {
	return &ChunkConfig{
		MinChunkSize: 256,      // 256 bytes
		MaxChunkSize: 8192,     // 8KB
		JitterFactor: 0.3,      // 30% jitter
		AddPadding:   true,
	}
}

// chunkDataRealistically - تقسیم data به chunks واقعی با jitter
func chunkDataRealistically(data []byte, cfg *ChunkConfig) [][]byte {
	if cfg == nil {
		cfg = DefaultChunkConfig()
	}
	
	var chunks [][]byte
	remaining := len(data)
	offset := 0
	
	for remaining > 0 {
		// محاسبه اندازه chunk با jitter
		baseSize := cfg.MinChunkSize + randInt(cfg.MaxChunkSize-cfg.MinChunkSize)
		
		// اعمال jitter
		jitter := int(float64(baseSize) * cfg.JitterFactor * (randFloat() - 0.5))
		chunkSize := baseSize + jitter
		
		// محدود کردن به remaining
		if chunkSize > remaining {
			chunkSize = remaining
		}
		
		// اطمینان از حداقل اندازه
		if chunkSize < cfg.MinChunkSize && remaining > cfg.MinChunkSize {
			chunkSize = cfg.MinChunkSize
		}
		
		chunk := data[offset : offset+chunkSize]
		
		// اضافه کردن padding اگه لازم باشه
		if cfg.AddPadding && randInt(10) < 3 { // 30% احتمال
			paddingSize := randInt(64) + 16 // 16-80 bytes
			padding := make([]byte, paddingSize)
			rand.Read(padding)
			chunk = append(chunk, padding...)
		}
		
		chunks = append(chunks, chunk)
		offset += chunkSize
		remaining -= chunkSize
	}
	
	return chunks
}

// randFloat - تولید float رندوم بین 0-1
func randFloat() float64 {
	b := make([]byte, 4)
	rand.Read(b)
	return float64(uint32(b[0])<<24|uint32(b[1])<<16|uint32(b[2])<<8|uint32(b[3])) / math.MaxUint32
}

func randInt(n int) int {
	if n <= 0 {
		return 0
	}
	b := make([]byte, 1)
	rand.Read(b)
	return int(b[0]) % n
}

// ============================================================================
// FIX 4: استفاده از Chunked Encoding در RoundTrip
// ============================================================================

/*
 * در HTTPConn.RoundTrip، بجای:
 *   if hc.Mimic.Chunked {
 *       req.ContentLength = -1
 *   }
 * 
 * استفاده کن از:
 */

func (hc *HTTPConn) setupChunkedRequest(req *http.Request, body []byte) io.Reader {
	if !hc.Mimic.Chunked {
		return bytes.NewReader(body)
	}
	
	// ✅ FIX: Chunking واقعی با jitter
	chunks := chunkDataRealistically(body, DefaultChunkConfig())
	
	// ساخت reader که chunks را با delay ارسال میکنه
	pr, pw := io.Pipe()
	
	go func() {
		defer pw.Close()
		
		for i, chunk := range chunks {
			// نوشتن chunk
			if _, err := pw.Write(chunk); err != nil {
				return
			}
			
			// اضافه کردن delay کوچک بین chunks (1-10ms)
			if i < len(chunks)-1 { // نه برای آخرین chunk
				time.Sleep(time.Duration(1+randInt(10)) * time.Millisecond)
			}
		}
	}()
	
	// Set ContentLength = -1 برای chunked transfer encoding
	req.ContentLength = -1
	
	return pr
}

// ============================================================================
// FIX 5: Session Management واقعی با rotation
// ============================================================================

// SessionManager - مدیریت sessions
type SessionManager struct {
	mu           sync.RWMutex
	sessions     map[string]*SessionInfo // sessionID -> SessionInfo
	oldToNew     map[string]string       // old sessionID -> new sessionID (برای rotation)
	cleanupTimer *time.Timer
}

// SessionInfo - اطلاعات یک session
type SessionInfo struct {
	SessionID   string
	CreatedAt   time.Time
	LastSeen    time.Time
	ClientIP    string
	RotatedFrom string // old session ID که از اون rotate شده
}

// NewSessionManager - ساخت session manager جدید
func NewSessionManager() *SessionManager {
	sm := &SessionManager{
		sessions: make(map[string]*SessionInfo),
		oldToNew: make(map[string]string),
	}
	
	// شروع cleanup goroutine
	sm.startCleanup()
	
	return sm
}

// CreateSession - ساخت session جدید
func (sm *SessionManager) CreateSession(clientIP string) string {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	sessionID := generateRandomSessionID()
	
	sm.sessions[sessionID] = &SessionInfo{
		SessionID: sessionID,
		CreatedAt: time.Now(),
		LastSeen:  time.Now(),
		ClientIP:  clientIP,
	}
	
	return sessionID
}

// RotateSession - rotate کردن session (ساخت ID جدید و نگاشت قدیمی → جدید)
func (sm *SessionManager) RotateSession(oldSessionID string) string {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	// اگه already rotate شده، برگردون همون
	if newID, exists := sm.oldToNew[oldSessionID]; exists {
		return newID
	}
	
	// ساخت session جدید
	newSessionID := generateRandomSessionID()
	
	// کپی اطلاعات از session قدیمی
	if oldInfo, exists := sm.sessions[oldSessionID]; exists {
		sm.sessions[newSessionID] = &SessionInfo{
			SessionID:   newSessionID,
			CreatedAt:   time.Now(),
			LastSeen:    time.Now(),
			ClientIP:    oldInfo.ClientIP,
			RotatedFrom: oldSessionID,
		}
		
		// نگاشت قدیمی → جدید (برای 5 دقیقه نگه دار)
		sm.oldToNew[oldSessionID] = newSessionID
		
		// بعد از 5 دقیقه نگاشت رو پاک کن
		go func() {
			time.Sleep(5 * time.Minute)
			sm.mu.Lock()
			delete(sm.oldToNew, oldSessionID)
			delete(sm.sessions, oldSessionID)
			sm.mu.Unlock()
		}()
	} else {
		// session قدیمی وجود نداره، یکی جدید بساز
		sm.sessions[newSessionID] = &SessionInfo{
			SessionID: newSessionID,
			CreatedAt: time.Now(),
			LastSeen:  time.Now(),
		}
	}
	
	return newSessionID
}

// ValidateSession - بررسی اعتبار session
func (sm *SessionManager) ValidateSession(sessionID string) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	// بررسی در sessions فعال
	if info, exists := sm.sessions[sessionID]; exists {
		// Update LastSeen
		info.LastSeen = time.Now()
		return true
	}
	
	// بررسی در نگاشت rotation
	if _, exists := sm.oldToNew[sessionID]; exists {
		return true
	}
	
	return false
}

// GetOrCreateSession - دریافت یا ساخت session
func (sm *SessionManager) GetOrCreateSession(sessionID, clientIP string) string {
	if sessionID == "" {
		return sm.CreateSession(clientIP)
	}
	
	sm.mu.RLock()
	_, exists := sm.sessions[sessionID]
	sm.mu.RUnlock()
	
	if exists {
		return sessionID
	}
	
	// session وجود نداره، یکی جدید بساز
	return sm.CreateSession(clientIP)
}

// startCleanup - شروع cleanup خودکار sessions قدیمی
func (sm *SessionManager) startCleanup() {
	go func() {
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		
		for range ticker.C {
			sm.cleanup()
		}
	}()
}

// cleanup - پاک کردن sessions منقضی شده
func (sm *SessionManager) cleanup() {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	now := time.Now()
	expireTime := 30 * time.Minute
	
	for id, info := range sm.sessions {
		if now.Sub(info.LastSeen) > expireTime {
			delete(sm.sessions, id)
		}
	}
	
	// پاک کردن نگاشت‌های rotation قدیمی
	for oldID := range sm.oldToNew {
		if _, exists := sm.sessions[oldID]; !exists {
			delete(sm.oldToNew, oldID)
		}
	}
}

// ============================================================================
// استفاده از SessionManager در Server
// ============================================================================

/*
 * در Server struct اضافه کن:
 *   SessionMgr *SessionManager
 * 
 * و در NewServer:
 *   s.SessionMgr = NewSessionManager()
 * 
 * و در HandleHTTP:
 */

func (s *Server) HandleHTTP_WithSessionMgr(w http.ResponseWriter, r *http.Request) {
	// ... existing validation code ...
	
	// ✅ FIX 5: دریافت یا ساخت session
	oldSessionID := extractSessionID(r)
	clientIP := r.RemoteAddr
	
	sessionID := s.SessionMgr.GetOrCreateSession(oldSessionID, clientIP)
	
	// اگه session تغییر کرده (rotate شده)، از session جدید استفاده کن
	if oldSessionID != "" && oldSessionID != sessionID {
		if s.Verbose {
			log.Printf("[SESSION_ROTATE] %s -> %s", oldSessionID, sessionID)
		}
	}
	
	// ... rest of processing ...
	
	// ✅ Set session cookie در response
	if s.Mimic != nil && s.Mimic.SessionCookie {
		// 20% احتمال rotate
		if randInt(100) < 20 {
			sessionID = s.SessionMgr.RotateSession(sessionID)
		}
		
		http.SetCookie(w, &http.Cookie{
			Name:     "session",
			Value:    sessionID,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
			MaxAge:   1800, // 30 minutes
		})
	}
	
	// ... write response ...
}

// ============================================================================
// Helper functions
// ============================================================================

func generateRandomSessionID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
