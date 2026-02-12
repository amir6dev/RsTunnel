package httpmux

import (
	"bytes"
	"io"
	"net/http"
	"sync"
	"time"
)

type Server struct {
	SessionMgr    *SessionManager
	Mimic         *MimicConfig
	Obfs          *ObfsConfig
	PSK           string
	activeSessMu  sync.RWMutex
	activeSess    *Session
}

func NewServer(timeoutSec int, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Server {
	if timeoutSec <= 0 { timeoutSec = 15 }
	return &Server{
		SessionMgr: NewSessionManager(time.Duration(timeoutSec) * time.Second),
		Mimic:      mimic,
		Obfs:       obfs,
		PSK:        psk,
	}
}

func (s *Server) setActiveSession(sess *Session) {
	s.activeSessMu.Lock()
	defer s.activeSessMu.Unlock()
	s.activeSess = sess
}

func (s *Server) getActiveSession() *Session {
	s.activeSessMu.RLock()
	defer s.activeSessMu.RUnlock()
	return s.activeSess
}

func (s *Server) HandleHTTP(w http.ResponseWriter, r *http.Request) {
	// 1. Session Handling
	sessionID := extractSessionID(r)
	if _, err := r.Cookie("SESSION"); err != nil {
		http.SetCookie(w, &http.Cookie{Name: "SESSION", Value: sessionID, Path: "/"})
	}
	sess := s.SessionMgr.GetOrCreate(sessionID)
	s.setActiveSession(sess)

	// 2. Read Request (Inbound Data)
	reqBody, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()

	if len(reqBody) > 0 {
		reqBody = StripObfuscation(reqBody, s.Obfs)
		plain, err := DecryptPSK(reqBody, s.PSK)
		if err == nil {
			reader := bytes.NewReader(plain)
			for {
				fr, err := ReadFrame(reader)
				if err != nil { break }
				s.handleFrame(sess, fr)
			}
		}
	}

	// 3. Long-Polling Logic (Outbound Data)
	var out bytes.Buffer

	// گام اول: انتظار برای حداقل یک فریم (Blocking Wait)
	// اگر صف خالی بود، تا 20 ثانیه صبر می‌کند
	select {
	case fr := <-sess.Outgoing:
		_ = WriteFrame(&out, fr)
	case <-time.After(20 * time.Second):
		// Timeout: هیچ دیتایی نبود، پاسخ خالی (Heartbeat) بفرست
	}

	// گام دوم: اگر دیتایی آمد، بقیه فریم‌های موجود را هم سریع بچسبان (Batching)
	if out.Len() > 0 {
		maxBatch := 128
		for i := 0; i < maxBatch; i++ {
			select {
			case fr := <-sess.Outgoing:
				_ = WriteFrame(&out, fr)
			default:
				i = maxBatch // خروج از حلقه اگر دیتایی نیست
			}
		}
	}

	// 4. Encrypt & Send Response
	// حتی اگر out خالی باشد، باید پاسخ رمزنگاری شده (شامل Padding) برود
	enc, _ := EncryptPSK(out.Bytes(), s.PSK)
	resp := ApplyObfuscation(enc, s.Obfs)
	ApplyDelay(s.Obfs)
	
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(resp)
}

func (s *Server) handleFrame(sess *Session, fr *Frame) {
	switch fr.Type {
	case FramePing:
		select {
		case sess.Outgoing <- &Frame{StreamID: 0, Type: FramePong}:
		default:
		}
	case FrameData:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		serverLinksMu.Unlock()
		if link != nil {
			link.c.Write(fr.Payload)
		}
	case FrameClose:
		serverLinksMu.Lock()
		link := serverLinks[fr.StreamID]
		delete(serverLinks, fr.StreamID)
		serverLinksMu.Unlock()
		if link != nil {
			link.c.Close()
		}
	}
}

func extractSessionID(r *http.Request) string {
	if c, _ := r.Cookie("SESSION"); c != nil && c.Value != "" { return c.Value }
	return "sess-" + RandString(12)
}